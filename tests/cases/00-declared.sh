# Declared checks: shell syntax, JSON/YAML parse, WebUI inline script syntax.

for f in "$ROOT"/module/*.sh "$ROOT"/module/META-INF/com/google/android/update-binary; do
    check "sh -n ${f#$ROOT/}" "$TEST_SH" -n "$f"
done

if command -v bash >/dev/null 2>&1; then
    check "bash -n .forgejo/module-ci.sh" bash -n "$ROOT/.forgejo/module-ci.sh"
else
    skip "bash -n .forgejo/module-ci.sh (no bash)"
fi

json_ok() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$1"
    else
        node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$1"
    fi
}
if command -v python3 >/dev/null 2>&1 || command -v node >/dev/null 2>&1; then
    for f in update.json .forgejo/update.json module/webroot/config.json; do
        check "json parse $f" json_ok "$ROOT/$f"
    done
else
    skip "json parse (no python3 or node)"
fi

if command -v python3 >/dev/null 2>&1 && python3 -I -c 'import yaml' 2>/dev/null; then
    for f in .forgejo/workflows/module-release.yml .github/workflows/android.yml; do
        check "yaml parse $f" python3 -I -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$ROOT/$f"
    done
else
    skip "yaml parse (no python3 yaml module)"
fi

if command -v node >/dev/null 2>&1; then
    sed -n '/^<script>$/,/^<\/script>$/p' "$ROOT/module/webroot/index.html" | sed '1d;$d' > "$WORK/webui.js"
    check "webui inline script extracted" test -s "$WORK/webui.js"
    check "node --check webui inline script" node --check "$WORK/webui.js"
else
    skip "node --check webui inline script (no node)"
fi
