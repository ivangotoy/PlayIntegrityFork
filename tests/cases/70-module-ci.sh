# .forgejo/module-ci.sh release mode, fully offline: a local bare repo stands in for the
# forge's git side, a stub curl for its API (fails on any request it does not know).
# Made-up token; the check is that it reaches the API as a header and never appears in argv.

need=""
for c in bash python3 git zip unzip sha256sum; do command -v "$c" >/dev/null 2>&1 || need="$need $c"; done
if [ -n "$need" ]; then
    skip "module-ci.sh release (missing:$need)"
else
    # rel_scenario <update.json at BASE, "" = none>: fresh fake forge, seed and build output, then one
    # release run; the module builds versionCode $HBUILT and the conf adds $HOFF
    HBUILT=100; HOFF=0
    rel_scenario() {
    new_root
    F="$W/forge"; R=owner/zzmodule; TOKEN="$(printf 'fake-%s-0123456789' token)"
    mkdir -p "$F/owner" "$W/state" "$W/run" "$W/seed/.forgejo"
    git init -q --bare "$F/$R.git"
    git --git-dir="$F/$R.git" symbolic-ref HEAD refs/heads/main
    printf 'ZIP_PREFIX=ZzModule\nVERSION_CODE_FLOOR=100\nVERSION_CODE_OFFSET=%s\n' "$HOFF" > "$W/seed/.forgejo/module-ci.conf"
    [ -z "$1" ] || printf '%s\n' "$1" > "$W/seed/.forgejo/update.json"
    (cd "$W/seed" && git init -q && git checkout -q -b main && git add -A \
        && git -c user.name=t -c user.email=t@example.invalid commit -q -m seed \
        && git push -q "$F/$R.git" main) > "$W/seed.log" 2>&1
    BASE="$(git --git-dir="$F/$R.git" rev-parse main)"
    OUTD="$W/build/.ci-out"; mkdir -p "$OUTD" "$W/mod"
    printf '%s\n\n' "$BASE" > "$OUTD/src"
    echo "" > "$OUTD/desc"
    printf 'id=zzmodule\nversion=v1\nversionCode=%s\nupdateJson=https://example.invalid/old.json\n' "$HBUILT" > "$W/mod/module.prop"
    echo 'echo hi' > "$W/mod/service.sh"
    (cd "$W/mod" && zip -qr9 "$OUTD/module.zip" .)
    REALGIT="$(command -v git)"
    printf '#!/bin/sh\nprintf "git %%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$W/argv.log" "$REALGIT" > "$W/bin/git"
    printf '#!/bin/sh\nS="%s"; F="%s"; R="%s"; TOKEN="%s"; LOG="%s"\n' "$W/state" "$F" "$R" "$TOKEN" "$W/argv.log" > "$W/bin/curl"
    cat >> "$W/bin/curl" <<'STUB'
printf 'curl %s\n' "$*" >> "$LOG"
m=GET; out=""; wfmt=""; att=""; data=""; hdrs=""
while [ "$#" -gt 1 ]; do
    case "$1" in
        -X) m="$2"; shift ;;
        -o) out="$2"; shift ;;
        -w) wfmt="$2"; shift ;;
        -F) att="${2#attachment=@}"; shift ;;
        -d) data="$2"; shift ;;
        -H) case "$2" in
                @-) hdrs="$hdrs$(cat)
" ;;
                @*) hdrs="$hdrs$(cat "${2#@}")
" ;;
                *) hdrs="$hdrs$2
" ;;
            esac; shift ;;
    esac
    shift
done
url="$1"
fail() { echo "curl stub: $*" >&2; exit 22; }
emit() { if [ -n "$out" ]; then cat > "$out"; else cat; fi; }
case "$url" in
    file://"$F"/api/v1/repos/"$R"/*|file://"$F"/attachments/*)
        printf '%s' "$hdrs" | grep -qx "Authorization: token $TOKEN" || fail "missing or wrong Authorization header for $url" ;;
esac
p="${url#file://$F}"
case "$m $p" in
    "GET /api/v1/repos/$R/releases/tags/"*|"GET /api/v1/repos/$R/tags/"*)
        if [ -n "$wfmt" ]; then [ -n "$out" ] && : > "$out"; printf 404; exit 0; fi
        [ -f "$S/published" ] || fail "tag before publish"
        printf '{"commit": {"sha": "%s"}}' "$(cat "$S/published")" | emit ;;
    "POST /api/v1/repos/$R/releases") printf '%s' "$data" > "$S/release-req"; printf '{"id": 7}' | emit ;;
    "POST /api/v1/repos/$R/releases/7/assets?name="*) cp "$att" "$S/asset.zip"; printf '{"id": 9}' | emit ;;
    "GET /api/v1/repos/$R/releases/7/assets/9") printf '{"browser_download_url": "file://%s/attachments/9"}' "$F" | emit ;;
    "GET /attachments/9") cat "$S/asset.zip" | emit ;;
    "PATCH /api/v1/repos/$R/releases/7")
        printf '%s' "$data" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["target_commitish"])' > "$S/published"
        echo '{}' | emit ;;
    "DELETE /api/v1/repos/$R/releases/7") : > "$S/deleted"; echo '{}' | emit ;;
    "GET /$R/releases/download/"*) [ -f "$S/published" ] || fail "download before publish"; cat "$S/asset.zip" | emit ;;
    "GET /$R/raw/branch/main/.forgejo/update.json") git --git-dir="$F/$R.git" show main:.forgejo/update.json | emit ;;
    *) fail "unexpected $m $url" ;;
esac
STUB
    chmod 755 "$W/bin/curl" "$W/bin/git"
    (cd "$W/run" && SERVER_URL="file://$F" REPOSITORY="$R" BASE_SHA="$BASE" RELEASE_TOKEN="$TOKEN" RUN_NUMBER=5 \
        bash "$ROOT/.forgejo/module-ci.sh" release "$W/build") > "$W/release.out" 2>&1
    rc=$?
    }
    rel_scenario ""
    check "module-ci.sh release exits 0 (offline forge)" test "$rc" -eq 0
    [ "$rc" -eq 0 ] || sed 's/^/    | /' "$W/release.out" | tail -n 15
    check "release published at the dispatched commit" test "$(cat "$W/state/published" 2>/dev/null)" = "$BASE"
    check "update.json committed with the new versionCode" sh -c 'git --git-dir="$1" show main:.forgejo/update.json | grep -q "\"versionCode\": 100"' - "$F/$R.git"
    check "uploaded zip points updateJson at the forge" sh -c 'unzip -p "$1" module.prop | grep -qx "updateJson=$2"' - "$W/state/asset.zip" "file://$F/$R/raw/branch/main/.forgejo/update.json"
    check "API calls were made" grep -q '^curl .*/api/v1/' "$W/argv.log"
    check "token never appears in curl/git argv" sh -c '! grep -qF "$1" "$2"' - "$TOKEN" "$W/argv.log"

    # the published update.json (at the dispatched commit) already holds the code this build would get:
    # the release goes one above it, in the zip, the release text and update.json
    rel_scenario "{\"versionCode\": $((HBUILT + HOFF))}"
    NEXT=$((HBUILT + HOFF + 1))
    check "versionCode equal to the published one: release exits 0" test "$rc" -eq 0
    [ "$rc" -eq 0 ] || sed 's/^/    | /' "$W/release.out" | tail -n 15
    check "versionCode equal to the published one: zip module.prop gets $NEXT" sh -c 'unzip -p "$1" module.prop | grep -qx "versionCode=$2"' - "$W/state/asset.zip" "$NEXT"
    check "versionCode equal to the published one: release text says $NEXT" grep -q "versionCode $NEXT" "$W/state/release-req"
    check "versionCode equal to the published one: update.json gets $NEXT" sh -c 'git --git-dir="$1" show main:.forgejo/update.json | grep -q "\"versionCode\": $2,"' - "$F/$R.git" "$NEXT"
    # an update.json whose versionCode is not an integer stops the release before anything is published
    for bad in '{"versionCode": "100"}' '{}' 'not json'; do
        rel_scenario "$bad"
        check "published update.json $bad: release fails" test "$rc" -ne 0
        check "published update.json $bad: no forge request, no push" sh -c '! grep -q "^curl " "$1" && test "$(git --git-dir="$2" rev-parse main)" = "$3"' - "$W/argv.log" "$F/$R.git" "$BASE"
        check "published update.json $bad: nothing uploaded or published" test ! -e "$W/state/asset.zip" -a ! -e "$W/state/published"
    done
fi

# release cleanup deletes only a release the forge still reports as a draft. The publish PATCH may be
# applied by the forge while its reply is lost; deleting on "PUBLISHED != 1" alone then removes a
# published release. Real: log/die/jget/api/cleanup and the publish statements (REQ= .. PUBLISHED=1)
# cut from module-ci.sh; stubbed: curl (fake forge at https://forge.invalid).
if ! command -v bash >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    skip "module-ci.sh release cleanup (bash/python3 missing)"
else
    RW="$(mktemp -d "$WORK/case.XXXXXX")"; mkdir -p "$RW/bin"
    {
        echo 'set -euo pipefail'
        echo 'API=https://forge.invalid/api/v1/repos/example/mod RELEASE_ID=7 PUBLISHED=0 SRC_SHA=0123456789abcdef0123456789abcdef01234567'
        echo 'DRAFT_REQUESTED=0 TAG=v9.9-ci7 REQ={}'
        echo 'AUTH_DIR=$(mktemp -d) AUTH_H=$AUTH_DIR/header; : > "$AUTH_H"'
        sed -n '/^log() {/p; /^die() {/p; /^jget() {/,/^print(d)/p; /^api() {/,/^}/p; /^cleanup() {/,/^}/p' "$ROOT/.forgejo/module-ci.sh"
        echo 'trap cleanup EXIT'
        echo 'if [ "$1" = create ]; then RELEASE_ID=""'
        sed -n '/^DRAFT_REQUESTED=1$/,/^RELEASE_ID="\$(api POST \/releases /p' "$ROOT/.forgejo/module-ci.sh"
        echo 'elif [ "$1" = publish ]; then'
        sed -n '/^REQ="\$(python3 -I -c .import json,sys;print(json.dumps({"draft":False/,/^PUBLISHED=1$/p' "$ROOT/.forgejo/module-ci.sh"
        echo 'else die "upload failed"; fi'
    } > "$RW/rel.sh"
    # fake curl: logs "METHOD URL"; POST exits $POST_RC, PATCH $PATCH_RC; GET of the release answers draft=$DRAFT or fails (DRAFT=fail)
    cat > "$RW/bin/curl" <<EOF
#!/bin/sh
m=GET; p=; for a in "\$@"; do [ "\$p" = -X ] && m=\$a; p=\$a; u=\$a; done
echo "\$m \$u" >> "$RW/calls"
case "\$m" in
  POST) exit "\${POST_RC:-0}" ;;
  PATCH) exit "\${PATCH_RC:-0}" ;;
  GET) [ "\$DRAFT" = fail ] && exit 22; printf '{"id": 7, "draft": %s}' "\$DRAFT" ;;
esac
EOF
    chmod 755 "$RW/bin/curl"
    rel() { _mode="$1"; shift; : > "$RW/calls"; env PATH="$RW/bin:$BASE_PATH" TMPDIR="$RW" "$@" bash "$RW/rel.sh" "$_mode" > "$RW/err" 2>&1; }
    check "release cleanup: cleanup(), api() and the publish statements found in module-ci.sh" \
        sh -c 'grep -q "^PUBLISHED=1$" "$1" && grep -q "^cleanup() {" "$1" && grep -q "^api() {" "$1"' - "$RW/rel.sh"
    rel publish PATCH_RC=28 DRAFT=false; rc=$?
    check "release cleanup: failed PATCH, forge reports published: job fails" test "$rc" -ne 0
    check "release cleanup: failed PATCH, forge reports published: PATCH sent, no DELETE" \
        sh -c 'grep -q "^PATCH " "$1" && ! grep -q "^DELETE " "$1"' - "$RW/calls"
    rel upload DRAFT=true; rc=$?
    check "release cleanup: failure before publish: job fails" test "$rc" -ne 0
    check "release cleanup: failure before publish deletes the draft" \
        grep -qx 'DELETE https://forge.invalid/api/v1/repos/example/mod/releases/7' "$RW/calls"
    rel publish PATCH_RC=28 DRAFT=fail; rc=$?
    check "release cleanup: failed PATCH, unreadable state: job fails" test "$rc" -ne 0
    check "release cleanup: failed PATCH, unreadable state: no DELETE" sh -c '! grep -q "^DELETE " "$1"' - "$RW/calls"
    check "release cleanup: failed PATCH, unreadable state: release id logged" grep -q 'release 7' "$RW/err"
    rel publish DRAFT=false; rc=$?
    check "release cleanup: good publish: exit 0" test "$rc" -eq 0
    check "release cleanup: good publish: no DELETE" sh -c '! grep -q "^DELETE " "$1"' - "$RW/calls"
    rel create POST_RC=28 DRAFT=true; rc=$?
    check "release cleanup: failed or unanswered draft request: job fails" test "$rc" -ne 0
    check "release cleanup: failed or unanswered draft request: POST sent, no DELETE" \
        sh -c 'grep -q "^POST " "$1" && ! grep -q "^DELETE " "$1"' - "$RW/calls"
    check "release cleanup: failed or unanswered draft request: tag logged for a check by hand" \
        sh -c 'grep -q "the draft request for v9.9-ci7 failed or its reply was lost" "$1" && ! grep -q "unbound variable" "$1"' - "$RW/err"
fi

# build step (module-ci.sh build): whatever the build user started is killed after the build,
# failed or not. setpriv and chown are stubs: the stub records a kill and never runs it (here the
# test user may well be the build uid, and `kill -9 -1` would end this session).
if ! command -v bash >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    skip "module-ci.sh build step (bash/git missing)"
else
    BW="$(mktemp -d "$WORK/case.XXXXXX")"; mkdir -p "$BW/bin"
    cat > "$BW/bin/setpriv" <<'EOF'
#!/bin/sh
case " $* " in *" kill "*) echo "kill-requested $*" >> "$SETPRIV_LOG"; exit 0 ;; esac
while [ $# -gt 0 ]; do case "$1" in --*) shift ;; *) break ;; esac; done
exec "$@"
EOF
    printf '#!/bin/sh\nexit 0\n' > "$BW/bin/chown"
    chmod 755 "$BW/bin/setpriv" "$BW/bin/chown"
    # build_step <ok|failed>: a work tree with this module-ci.sh and a conf whose build() passes or fails
    build_step() {
        _b="$BW/$1"; mkdir -p "$_b/.forgejo"
        cp "$ROOT/.forgejo/module-ci.sh" "$_b/.forgejo/"
        if [ "$1" = ok ]; then
            printf 'build() { echo zip > "$OUT/module.zip"; }\n' > "$_b/.forgejo/module-ci.conf"
        else
            printf 'build() { echo "stub build failed" >&2; return 1; }\n' > "$_b/.forgejo/module-ci.conf"
        fi
        (cd "$_b" && git init -q && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -qm t) > /dev/null 2>&1
        : > "$_b/setpriv.log"
        if [ "$(PATH="$BW/bin:$BASE_PATH" command -v setpriv)" != "$BW/bin/setpriv" ]; then
            bad "build step $1: setpriv stub not first on PATH, not run"; return
        fi
        _rc=0
        (cd "$_b" && env PATH="$BW/bin:$BASE_PATH" SETPRIV_LOG="$_b/setpriv.log" SERVER_URL=https://forge.invalid \
            REPOSITORY=owner/repo BASE_SHA="$(git rev-parse HEAD)" bash .forgejo/module-ci.sh build "$_b") > "$_b/out.log" 2>&1 || _rc=$?
        if [ "$1" = ok ]; then _want=0; [ -f "$_b/.ci-out/module.zip" ] && _res=zip || _res=missing
        else _want=1; grep -q "stub build failed" "$_b/out.log" && _res=stub-failure || _res=missing; fi
        if [ "$([ "$_rc" = 0 ] && echo 0 || echo 1)" = "$_want" ] && [ "$_res" != missing ] \
            && ! grep -q "unbound variable" "$_b/out.log" && grep -q 'kill-requested .*--reuid=1000 .*kill -9 -1' "$_b/setpriv.log"; then
            ok "module-ci.sh build step $1: exit as expected, build user's processes killed"
        else
            bad "module-ci.sh build step $1 (rc=$_rc, $_res, kills: $(grep -c kill-requested "$_b/setpriv.log")): $(tail -n 2 "$_b/out.log" | tr '\n' ' ')"
        fi
    }
    build_step ok
    build_step failed
fi
