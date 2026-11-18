# migrate.sh conversions with made-up values.

new_root
cat > "$MOD/custom.pif.prop" <<'PIF'
MANUFACTURER=Google
MODEL=Pixel Test
FINGERPRINT=google/zzdev/zzdev:99/ZZ1A.250101.001/1234567:user/release-keys
SECURITY_PATCH=2025-01-05  # trailing comment
DEVICE_INITIAL_SDK_INT=32
#ro.build.version.security_patch=2025-01-05
spoofProvider=0
spoofVendingFinger=google/zzother/zzother:98/ZZ0A.240101.001/7654321:user/release-keys
verboseLogs=2
PIF
(cd "$MOD" && "$TEST_SH" "$MOD/migrate.sh" -f "$MOD/custom.pif.prop") > "$W/m.out" 2>&1
check "migrate -f prop exits 0" test "$?" -eq 0
C="$MOD/custom.pif.prop"
check "prop: old file kept as .bak" test -f "$C.bak"
check "prop: MODEL with space kept" has_line "$C" "MODEL=Pixel Test"
check "prop: comment stripped from SECURITY_PATCH" has_line "$C" "SECURITY_PATCH=2025-01-05"
check "prop: ID derived from FINGERPRINT" has_line "$C" "ID=ZZ1A.250101.001"
check "prop: RELEASE derived" has_line "$C" "RELEASE=99"
check "prop: security_patch comment kept" has_line "$C" "#ro.build.version.security_patch=2025-01-05"
check "prop: spoofProvider kept" has_line "$C" "spoofProvider=0"
check "prop: fingerprint-valued spoofVendingFinger kept" has_line "$C" "spoofVendingFinger=google/zzother/zzother:98/ZZ0A.240101.001/7654321:user/release-keys"
check "prop: verboseLogs kept" has_line "$C" "verboseLogs=2"
check "prop: first api level" has_line "$C" "ro.product.first_api_level=32"

# prop -> json
(cd "$MOD" && "$TEST_SH" "$MOD/migrate.sh" -j "$MOD/custom.pif.prop") > "$W/j.out" 2>&1
J="$MOD/custom.pif.json"
check "migrate -j exits 0" test "$?" -eq 0
check "json: MODEL" has_line "$J" '    "MODEL": "Pixel Test",'
check "json: commented security_patch" has_line "$J" '    //"ro.build.version.security_patch": "2025-01-05",'
check "json: last entry closes object" test "$(tail -n 2 "$J" | tr -d '\n')" = '    "verboseLogs": "2"}'
if command -v python3 >/dev/null 2>&1; then
    check "json: output parses after comment removal" python3 -I -c 'import json,re,sys; json.loads(re.sub(r"(?m)^\s*//.*$", "", open(sys.argv[1]).read()))' "$J"
fi

# json -> prop round trip
rm -f "$C"
(cd "$MOD" && "$TEST_SH" "$MOD/migrate.sh" -p "$J") > "$W/p.out" 2>&1
check "migrate -p exits 0" test "$?" -eq 0
check "json->prop: MODEL" has_line "$C" "MODEL=Pixel Test"
check "json->prop: spoofVendingFinger fingerprint" has_line "$C" "spoofVendingFinger=google/zzother/zzother:98/ZZ0A.240101.001/7654321:user/release-keys"
check "json->prop: security_patch comment" has_line "$C" "#ro.build.version.security_patch=2025-01-05"

# already migrated file is left alone without -f
cp "$C" "$W/before"
(cd "$MOD" && "$TEST_SH" "$MOD/migrate.sh" "$C") > "$W/n.out" 2>&1
check "no migration required exits 1" test "$?" -eq 1
check "no migration required leaves file" cmp -s "$C" "$W/before"

# config values are data: shell syntax in a prop value must not run (payloads only touch $W)
new_root
cat > "$MOD/custom.pif.prop" <<PIF
MANUFACTURER=Google
MODEL=Pixel \$(touch $W/pwned-field)
FINGERPRINT=google/zzdev/zzdev:99/ZZ1A.250101.001/1234567:user/release-keys
PIF
cat > "$W/old.prop" <<PIF
verboseLogs=0
spoofBuild=1\$(touch $W/pwned-setting)
PIF
mkdir -p "$W/out" && cp "$W/old.prop" "$W/out/custom.pif.prop"
(cd "$MOD" && "$TEST_SH" "$MOD/migrate.sh" -f "$MOD/custom.pif.prop") > "$W/m.out" 2>&1
check "prop field value is not executed" test ! -e "$W/pwned-field"
check "prop field value kept literally" has_line "$MOD/custom.pif.prop" "MODEL=Pixel \$(touch $W/pwned-field)"
(cd "$MOD" && "$TEST_SH" "$MOD/migrate.sh" -f "$MOD/custom.pif.prop" "$W/out/custom.pif.prop") > "$W/m2.out" 2>&1
check "prop advanced setting value is not executed" test ! -e "$W/pwned-setting"

# WebUI import of a JSON file into custom.pif.prop, then forced prop migration
new_root
cat > "$MOD/custom.pif.prop" <<'PIF'
{
  "MANUFACTURER": "Google",
  "MODEL": "Pixel Test",
  "FINGERPRINT": "google/zzdev/zzdev:99/ZZ1A.250101.001/1234567:user/release-keys"
}
PIF
(cd "$MOD" && "$TEST_SH" "$MOD/migrate.sh" -p "$MOD/custom.pif.prop") > "$W/w.out" 2>&1
check "json content in .prop: migrate -p exits 0" test "$?" -eq 0
check "json content in .prop: advanced settings written" has_line "$MOD/custom.pif.prop" "spoofBuild=1"

# json with an escaped quote in a value keeps it escaped when rewritten as json
new_root
cat > "$MOD/custom.pif.json" <<'PIF'
{
  "MANUFACTURER": "Google",
  "MODEL": "Pixel \"Q\" Test",
  "FINGERPRINT": "google/zzdev/zzdev:99/ZZ1A.250101.001/1234567:user/release-keys",
  "verboseLogs": "0"
}
PIF
(cd "$MOD" && "$TEST_SH" "$MOD/migrate.sh" -f "$MOD/custom.pif.json") > "$W/q.out" 2>&1
check "json escaped quote kept" has_line "$MOD/custom.pif.json" '    "MODEL": "Pixel \"Q\" Test",'

# custom.pif.json content is not run as shell code (payloads only touch $W)
new_root
cat > "$MOD/custom.pif.json" <<PIF
{
  "MANUFACTURER": "Google",
  "MODEL": "Pixel \$(touch $W/pwned-json)",
  "FINGERPRINT": "google/zzdev/zzdev:99/ZZ1A.250101.001/1234567:user/release-keys"
}
PIF
cp "$MOD/custom.pif.json" "$W/orig.json"
(cd "$MOD" && "$TEST_SH" "$MOD/migrate.sh" --install "$MOD/custom.pif.json") > "$W/j1.out" 2>&1
rc=$?
check "json \$() value is not executed" test ! -e "$W/pwned-json"
check "json refused: non-zero exit" test "$rc" -ne 0
check "json refused: warning names the file" has_text "$W/j1.out" "Refusing to migrate $MOD/custom.pif.json"
check "json refused: original file left unchanged" cmp -s "$MOD/custom.pif.json" "$W/orig.json"
check "json refused: no .bak written" test ! -e "$MOD/custom.pif.json.bak"
check "json refused: value not echoed" sh -c '! grep -q "touch" "$1"' - "$W/j1.out"

new_root
cat > "$MOD/custom.pif.json" <<PIF
{
  "MANUFACTURER": "Google",
  "FINGERPRINT": "google/zzdev/zzdev:99/ZZ1A.250101.001/1234567:user/release-keys",
  "BAR": "x"; touch $W/pwned-outside; "y",
  "FOO": "\\\`touch $W/pwned-unused\\\`"
}
PIF
(cd "$MOD" && "$TEST_SH" "$MOD/migrate.sh" -f "$MOD/custom.pif.json") > "$W/j2.out" 2>&1
check "json shell syntax outside strings is not executed" test ! -e "$W/pwned-outside"
check "json escaped backtick in an unused field is not executed" test ! -e "$W/pwned-unused"

# an ordinary custom.pif.json (comments, \/ \" A, & ; ( ) < > ') migrates exactly as before
new_root
cp "$ROOT/tests/fixtures/migrate/sample.pif.json" "$MOD/custom.pif.json"
(cd "$MOD" && "$TEST_SH" "$MOD/migrate.sh" -f "$MOD/custom.pif.json") > "$W/j3.out" 2>&1
check "ordinary json: migrate exits 0" test "$?" -eq 0
check "ordinary json: output byte-identical to the previous migrate.sh" cmp -s "$MOD/custom.pif.json" "$ROOT/tests/fixtures/migrate/sample.expected.json"
