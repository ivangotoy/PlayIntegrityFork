# WebUI import (module/webroot/index.html jsonToProp): a picked or downloaded custom.pif.json is
# converted to prop text with literal values before it is written (base64) to custom.pif.prop.
# Values a prop line can't carry unchanged are skipped (optional keys, names reported, never values)
# or fail the import (build fields migrate.sh needs). The converted text then goes through
# migrate.sh in 91-webui-migrate.sh, which needs no node.

if ! command -v node >/dev/null 2>&1; then
    skip "webui json import conversion (no node)"
else
    new_root
    H="$ROOT/module/webroot/index.html"
    FX="$ROOT/tests/fixtures/webui"
    sed -n '/^function jsonToProp(/,/^}$/p' "$H" > "$W/conv.js"
    cat >> "$W/conv.js" <<'JS'
const fs = require("fs");
const skipped = [];
let out;
try { out = { text: jsonToProp(fs.readFileSync(process.argv[2], "utf8"), skipped), skipped }; }
catch (e) { out = { error: String(e.message) }; }
fs.writeFileSync(process.argv[3], JSON.stringify(out));
if (out.text !== undefined) process.stdout.write(out.text);
JS
    node "$W/conv.js" "$FX/clean.pif.json" "$W/clean.json" > "$W/clean.prop"
    check "import: ordinary JSON converts exactly as before (golden from the previous converter)" cmp -s "$W/clean.prop" "$FX/clean.expected.prop"
    check "import: ordinary JSON skips nothing" grep -qF '"skipped":[]' "$W/clean.json"
    node "$W/conv.js" "$FX/import.pif.json" "$W/conv.json" > "$W/import.prop"
    check "import: values written as literal text" cmp -s "$W/import.prop" "$FX/import.expected.prop"
    check "import: value with a newline is not written" sh -c '! grep -q "^spoofSignature=1\|^NOTE=" "$1"' - "$W/import.prop"
    check "import: value with # is not written" sh -c '! grep -q "^ro.zz.hash=" "$1"' - "$W/import.prop"
    check "import: skipped keys reported" grep -qF '"skipped":["NOTE","ro.zz.hash","ro.zz.tab"]' "$W/conv.json"
    check "import: skipped values not reported" sh -c '! grep -q "line1\|a#b\|spoofSignature" "$1"' - "$W/conv.json"

    node "$W/conv.js" "$FX/import-bad.pif.json" "$W/bad.json" > "$W/bad.out"
    check "import: build field with a newline fails the import" grep -q '"error":"Not imported: MODEL ' "$W/bad.json"
    check "import: failed import produces no text" test ! -s "$W/bad.out"
    check "import: failure message holds no value" sh -c '! grep -q spoofSignature "$1"' - "$W/bad.json"

    printf 'MODEL=Already Prop\n' > "$W/prop.in"
    node "$W/conv.js" "$W/prop.in" "$W/p.json" > "$W/prop.out"
    check "import: prop text passes through unchanged" cmp -s "$W/prop.in" "$W/prop.out"
    printf '{ "MODEL": "x", \n' > "$W/broken.in"
    node "$W/conv.js" "$W/broken.in" "$W/b.json" > "$W/broken.out"
    check "import: text that is not a JSON object passes through unchanged" cmp -s "$W/broken.in" "$W/broken.out"
    check "webui: import handlers log skipped keys" test "$(grep -c 'Skipped entries a prop line' "$H")" -eq 2
fi
