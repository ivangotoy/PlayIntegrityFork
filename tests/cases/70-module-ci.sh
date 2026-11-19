# .forgejo/module-ci.sh release mode, fully offline: a local bare repo stands in for the
# forge's git side, a stub curl for its API (fails on any request it does not know).
# Made-up token; the check is that it reaches the API as a header and never appears in argv.

need=""
for c in bash python3 git zip unzip sha256sum; do command -v "$c" >/dev/null 2>&1 || need="$need $c"; done
if [ -n "$need" ]; then
    skip "module-ci.sh release (missing:$need)"
else
    new_root
    F="$W/forge"; R=owner/zzmodule; TOKEN=fake-token-0123456789
    mkdir -p "$F/owner" "$W/state" "$W/run" "$W/seed/.forgejo"
    git init -q --bare "$F/$R.git"
    git --git-dir="$F/$R.git" symbolic-ref HEAD refs/heads/main
    printf 'ZIP_PREFIX=ZzModule\nVERSION_CODE_FLOOR=100\n' > "$W/seed/.forgejo/module-ci.conf"
    echo '{}' > "$W/seed/.forgejo/update.json"
    (cd "$W/seed" && git init -q && git checkout -q -b main && git add -A \
        && git -c user.name=t -c user.email=t@example.invalid commit -q -m seed \
        && git push -q "$F/$R.git" main) > "$W/seed.log" 2>&1
    BASE="$(git --git-dir="$F/$R.git" rev-parse main)"
    OUTD="$W/build/.ci-out"; mkdir -p "$OUTD" "$W/mod"
    printf '%s\n\n' "$BASE" > "$OUTD/src"
    echo "" > "$OUTD/desc"
    printf 'id=zzmodule\nversion=v1\nversionCode=100\nupdateJson=https://example.invalid/old.json\n' > "$W/mod/module.prop"
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
    "POST /api/v1/repos/$R/releases") printf '{"id": 7}' | emit ;;
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
    check "module-ci.sh release exits 0 (offline forge)" test "$rc" -eq 0
    [ "$rc" -eq 0 ] || sed 's/^/    | /' "$W/release.out" | tail -n 15
    check "release published at the dispatched commit" test "$(cat "$W/state/published" 2>/dev/null)" = "$BASE"
    check "update.json committed with the new versionCode" sh -c 'git --git-dir="$1" show main:.forgejo/update.json | grep -q "\"versionCode\": 100"' - "$F/$R.git"
    check "uploaded zip points updateJson at the forge" sh -c 'unzip -p "$1" module.prop | grep -qx "updateJson=$2"' - "$W/state/asset.zip" "file://$F/$R/raw/branch/main/.forgejo/update.json"
    check "API calls were made" grep -q '^curl .*/api/v1/' "$W/argv.log"
    check "token never appears in curl/git argv" sh -c '! grep -qF "$1" "$2"' - "$TOKEN" "$W/argv.log"
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
        echo 'AUTH_DIR=$(mktemp -d) AUTH_H=$AUTH_DIR/header; : > "$AUTH_H"'
        sed -n '/^log() {/p; /^die() {/p; /^jget() {/,/^print(d)/p; /^api() {/,/^}/p; /^cleanup() {/,/^}/p' "$ROOT/.forgejo/module-ci.sh"
        echo 'trap cleanup EXIT'
        echo 'if [ "$1" = publish ]; then'
        sed -n '/^REQ="\$(python3 -I -c .import json,sys;print(json.dumps({"draft":False/,/^PUBLISHED=1$/p' "$ROOT/.forgejo/module-ci.sh"
        echo 'else die "upload failed"; fi'
    } > "$RW/rel.sh"
    # fake curl: logs "METHOD URL"; PATCH exits $PATCH_RC; GET of the release answers draft=$DRAFT or fails (DRAFT=fail)
    cat > "$RW/bin/curl" <<EOF
#!/bin/sh
m=GET; p=; for a in "\$@"; do [ "\$p" = -X ] && m=\$a; p=\$a; u=\$a; done
echo "\$m \$u" >> "$RW/calls"
case "\$m" in
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
fi
