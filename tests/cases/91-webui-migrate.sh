# Converted WebUI imports (fixtures written by jsonToProp, checked in 90-webui.sh) through the
# migrate.sh call the WebUI makes (sh migrate.sh -p custom.pif.prop) under $TEST_SH, mksh and dash
# where installed, then through the native config loader when 55-native-config.sh built it.

FX="$ROOT/tests/fixtures/webui"
L="$WORK/native-config/load"
for S in "$TEST_SH" mksh dash; do
    command -v "$S" >/dev/null 2>&1 || { skip "converted import + migrate -p under $S (not installed)"; continue; }
    new_root
    C="$MOD/custom.pif.prop"
    cp "$FX/import.expected.prop" "$C"
    (cd "$MOD" && "$S" "$MOD/migrate.sh" -p "$C") > "$W/m.out" 2>&1
    check "import + migrate -p ($S): exits 0" test "$?" -eq 0
    check "import + migrate -p ($S): MODEL kept literally" has_line "$C" 'MODEL=Pixel "Q" Test/AA & co'
    check "import + migrate -p ($S): FINGERPRINT kept" has_line "$C" "FINGERPRINT=google/zzdev/zzdev:99/ZZ1A.250101.001/1234567:user/release-keys"
    check "import + migrate -p ($S): derived ID" has_line "$C" "ID=ZZ1A.250101.001"
    check "import + migrate -p ($S): disabled security_patch stays disabled" has_line "$C" "#ro.build.version.security_patch=2025-01-05"
    check "import + migrate -p ($S): spoofProvider kept" has_line "$C" "spoofProvider=0"
    check "import + migrate -p ($S): one MODEL line, no injected setting" sh -c 'test "$(grep -c "^MODEL=" "$1")" -eq 1 && ! grep -q "^spoofSignature=1" "$1"' - "$C"
    if [ -x "$L" ]; then
        "$L" < "$C" > "$W/native.out"
        check "import round trip ($S): native config gets the original MODEL" grep -qF '"MODEL":"Pixel \"Q\" Test/AA & co"' "$W/native.out"
    fi
    cp "$FX/clean.expected.prop" "$C"
    (cd "$MOD" && "$S" "$MOD/migrate.sh" -p "$C") > "$W/c.out" 2>&1
    check "clean import + migrate -p ($S): fields kept" sh -c 'grep -qx "MODEL=Pixel Test Pro" "$1" && grep -qx "spoofVendingFinger=google/zzother/zzother:98/ZZ0A.240101.001/7654321:user/release-keys,test-keys" "$1" && grep -qx "verboseLogs=2" "$1"' - "$C"
done
