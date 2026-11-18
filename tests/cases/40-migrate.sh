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
