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
        -H) if [ "$2" = @- ]; then hdrs="$hdrs$(cat)
"; else hdrs="$hdrs$2
"; fi; shift ;;
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
