# WebUI import (module/webroot/index.html): a picked or downloaded custom.pif.json is converted to
# prop text before it is written to custom.pif.prop (still base64-encoded on the way to the shell),
# then migrated with migrate.sh -p as the WebUI does, then loaded by the native config path.

if ! command -v node >/dev/null 2>&1; then
    skip "webui json import (no node)"
else
    new_root
    H="$ROOT/module/webroot/index.html"
    sed -n '/^function jsonToProp(text) {$/,/^}$/p' "$H" > "$W/conv.js"
    [ -s "$W/conv.js" ] || echo 'function jsonToProp(text) { return text; }' > "$W/conv.js"
    cat >> "$W/conv.js" <<'JS'
const fs = require("fs");
process.stdout.write(jsonToProp(fs.readFileSync(process.argv[2], "utf8")));
JS
    node "$W/conv.js" "$ROOT/tests/fixtures/webui/import.pif.json" > "$MOD/custom.pif.prop"
    C="$MOD/custom.pif.prop"
    check "import: JSON becomes prop lines" has_line "$C" "MANUFACTURER=Google"
    check "import: value kept as an escaped JSON string body, # escaped" has_line "$C" 'MODEL=Pixel \"Q\" Test/AA \u00231 & co'
    check "import: number value" has_line "$C" "DEVICE_INITIAL_SDK_INT=32"
    check "import: newline stays escaped, no extra line" has_line "$C" 'NOTE=line1\nline2'
    check "import: commented entry stays commented" has_line "$C" "#ro.build.version.security_patch=2025-01-05"
    check "import: section comments kept" has_line "$C" "# Build Fields"
    printf 'MODEL=Already Prop\n' > "$W/prop.in"
    node "$W/conv.js" "$W/prop.in" > "$W/prop.out"
    check "import: prop text passes through unchanged" cmp -s "$W/prop.in" "$W/prop.out"
    printf '{ "MODEL": "x", \n' > "$W/broken.in"
    node "$W/conv.js" "$W/broken.in" > "$W/broken.out"
    check "import: text that is not a JSON object passes through unchanged" cmp -s "$W/broken.in" "$W/broken.out"

    (cd "$MOD" && "$TEST_SH" "$MOD/migrate.sh" -p "$C") > "$W/m.out" 2>&1
    check "import + migrate -p: exits 0" test "$?" -eq 0
    check "import + migrate -p: MODEL filled" has_line "$C" 'MODEL=Pixel \"Q\" Test/AA \u00231 & co'
    check "import + migrate -p: FINGERPRINT filled" has_line "$C" "FINGERPRINT=google/zzdev/zzdev:99/ZZ1A.250101.001/1234567:user/release-keys"
    check "import + migrate -p: derived ID" has_line "$C" "ID=ZZ1A.250101.001"
    check "import + migrate -p: disabled security_patch stays disabled" has_line "$C" "#ro.build.version.security_patch=2025-01-05"
    check "import + migrate -p: spoofProvider kept" has_line "$C" "spoofProvider=0"

    L="$WORK/native-config/load"
    if [ -x "$L" ]; then
        "$L" < "$C" > "$W/native.out"
        check "import round trip: native config gets the original MODEL" node -e '
const fs = require("fs");
const want = JSON.parse(fs.readFileSync(process.argv[1], "utf8").replace(/^\s*\/\/.*$/mg, "")).MODEL;
const got = JSON.parse(fs.readFileSync(process.argv[2], "utf8")).MODEL;
process.exit(got === want ? 0 : 1);' "$ROOT/tests/fixtures/webui/import.pif.json" "$W/native.out"
    else
        skip "import round trip through the native loader (55-native-config not built)"
    fi
fi
