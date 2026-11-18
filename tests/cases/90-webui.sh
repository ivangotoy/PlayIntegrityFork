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

# every measured row (followup2 evidence: migrate.sh under bash, busybox sh, dash, mksh, then the native
# reader): a value or key that travels is written literally, one that does not is never written
if command -v node >/dev/null 2>&1; then
    sed -n '/^function jsonToProp(/,/^}$/p' "$ROOT/module/webroot/index.html" > "$W/rows.js"
    cat >> "$W/rows.js" <<'JS'
const fs = require("fs");
const rows = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const FP = "google/zzdev/zzdev:99/ZZ1A.250101.001/1234567:user/release-keys";
const bad = [];
for (const [name, r] of Object.entries(rows)) {
  const obj = { MANUFACTURER: "Google", MODEL: "Pixel", FINGERPRINT: FP };
  let k, v;
  if (r.key !== undefined) { k = r.key; v = "val"; } else { k = r.field; v = r.value; }
  obj[k] = v;
  const skipped = []; let text = null;
  try { text = jsonToProp(JSON.stringify(obj, null, 2), skipped); } catch (e) { text = null; }
  const written = text !== null && text.split("\n").includes(k + "=" + v);
  const dropped = text === null || skipped.includes(k);
  if (r.travels ? !written : !dropped) bad.push(name);
}
console.log(bad.join(" "));
process.exit(bad.length ? 1 : 0);
JS
    node "$W/rows.js" "$ROOT/tests/fixtures/webui/measured.json" > "$W/rows.out" 2>&1
    check "import: measured travel table holds ($(head -c 200 "$W/rows.out"))" test "$?" -eq 0
fi
