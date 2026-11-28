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
mj_rc=$?
J="$MOD/custom.pif.json"
check "migrate -j exits 0" test "$mj_rc" -eq 0
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
check "prop field value: migrate.sh wrote a new file" test -e "$MOD/custom.pif.prop.bak"
check "prop field value is not executed" test ! -e "$W/pwned-field"
check "prop field value kept literally" has_line "$MOD/custom.pif.prop" "MODEL=Pixel \$(touch $W/pwned-field)"
(cd "$MOD" && "$TEST_SH" "$MOD/migrate.sh" -f "$MOD/custom.pif.prop" "$W/out/custom.pif.prop") > "$W/m2.out" 2>&1
check "prop advanced setting value: migrate.sh wrote a new file" test -e "$W/out/custom.pif.prop.bak"
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
check "json shell syntax outside strings: migrate.sh ran (refused or migrated)" sh -c 'grep -q "Refusing to migrate" "$1" || test -e "$2.bak"' - "$W/j2.out" "$MOD/custom.pif.prop"
check "json shell syntax outside strings is not executed" test ! -e "$W/pwned-outside"
check "json escaped backtick in an unused field is not executed" test ! -e "$W/pwned-unused"

# an ordinary custom.pif.json (comments, \/ \" A, & ; ( ) < > ') migrates exactly as before
new_root
cp "$ROOT/tests/fixtures/migrate/sample.pif.json" "$MOD/custom.pif.json"
(cd "$MOD" && "$TEST_SH" "$MOD/migrate.sh" -f "$MOD/custom.pif.json") > "$W/j3.out" 2>&1
check "ordinary json: migrate exits 0" test "$?" -eq 0
check "ordinary json: output byte-identical to the previous migrate.sh" cmp -s "$MOD/custom.pif.json" "$ROOT/tests/fixtures/migrate/sample.expected.json"

# backslash-quote breakout of the second eval, and // that is no shell comment once newlines are gone
# migrate_ran <output> <config>: migrate.sh got as far as refusing the file or writing a new one (.bak),
# so a "not executed" check after it is not passing only because migrate.sh never ran
migrate_ran() { grep -q "Refusing to migrate" "$1" || test -e "$2.bak"; }
json_case() {
    # $1 marker name, $2 extra json lines (raw)
    new_root
    printf '{\n  "MANUFACTURER": "Google",\n  "FINGERPRINT": "google/zzdev/zzdev:99/ZZ1A.250101.001/1234567:user/release-keys",\n%s\n  "verboseLogs": "0"\n}\n' "$2" | sed "s#@W@#$W#g" > "$MOD/custom.pif.json"
    (cd "$MOD" && "$TEST_SH" "$MOD/migrate.sh" -f "$MOD/custom.pif.json") > "$W/$1.out" 2>&1
    check "json case $1: migrate.sh ran (refused or migrated)" migrate_ran "$W/$1.out" "$MOD/custom.pif.json"
}
json_case bsq "  \"MODEL\": \"a\\\\\\\" ; touch @W@/pwned-bsq ; : \\\\\\\"\","
check "fixture holds the backslash-quote sequence" sh -c 'cat "$1" "$1.bak" 2>/dev/null | grep -qF "$2"' - "$MOD/custom.pif.json" 'a\\\" ; touch /'
check "json backslash before escaped quote is not executed" test ! -e "$W/pwned-bsq"
json_case midword "  \"MODEL\": \"x\",//; touch @W@/pwned-midword"
check "json mid-word // text is not executed" test ! -e "$W/pwned-midword"
json_case col0 "  \"MODEL\": \"x\",
// note; touch @W@/pwned-col0"
check "json column-0 // text is not executed" test ! -e "$W/pwned-col0"
json_case valend1 "  \"MODEL\": \"x\",
  \"FOO\": \"y BRAND\", // n: z; touch @W@/pwned-valend1"
check "json key name at a value end, colon in a comment: not executed" test ! -e "$W/pwned-valend1"
json_case valend2 "  \"MODEL\": \"x\",
  \"FOO\": \"y BRAND\",
  \"a:b; touch @W@/pwned-valend2; //\": \"v\","
check "json key name at a value end, colon in a key: not executed" test ! -e "$W/pwned-valend2"
json_case okcolon "  \"MODEL\": \"x\", // see: notes
  \"FOO\": \"time 10:30\","
check "json ordinary colons in comments and values: not refused" sh -c '! grep -q Refusing "$1" && test -e "$2.bak" && grep -q "Advanced Settings" "$2"' - "$W/okcolon.out" "$MOD/custom.pif.json"
json_case splitkey "  \"MODEL\": \"x\",
  \"FOO\": \"y BRA
ND\", // n: z; touch @W@/pwned-splitkey"
check "json key name split across lines: not executed" test ! -e "$W/pwned-splitkey"
# mksh (Android's /system/bin/sh) echo expands \xHH and \uHHHH; both may spell $( for the second eval
for form in x24 u0024 U00000024; do
    new_root
    printf '{\n  "MANUFACTURER": "Google",\n  "MODEL": "x\\\\%s(touch %s/pwned-%s)",\n  "FINGERPRINT": "google/zzdev/zzdev:99/ZZ1A.250101.001/1234567:user/release-keys"\n}\n' "$form" "$W" "$form" > "$MOD/custom.pif.json"
    (cd "$MOD" && "$TEST_SH" "$MOD/migrate.sh" -f "$MOD/custom.pif.json") > "$W/esc-$form.out" 2>&1
    check "json echo escape \\$form making \$: refused" has_text "$W/esc-$form.out" "Refusing to migrate"
    if command -v mksh >/dev/null 2>&1; then
        new_root
        printf '{\n  "MANUFACTURER": "Google",\n  "MODEL": "x\\\\%s(touch %s/pwned-mksh-%s)",\n  "FINGERPRINT": "google/zzdev/zzdev:99/ZZ1A.250101.001/1234567:user/release-keys"\n}\n' "$form" "$W" "$form" > "$MOD/custom.pif.json"
        (cd "$MOD" && mksh "$MOD/migrate.sh" -f "$MOD/custom.pif.json") > "$W/mksh-$form.out" 2>&1
        check "json echo escape \\$form under mksh: not executed" test ! -e "$W/pwned-mksh-$form"
    else
        skip "json echo escape \\$form under mksh (no mksh)"
    fi
done
new_root
printf '{\n  "MANUFACTURER": "Google",\n  "MODEL": "Pixel \\u0041 \\x41",\n  "FINGERPRINT": "google/zzdev/zzdev:99/ZZ1A.250101.001/1234567:user/release-keys"\n}\n' > "$MOD/custom.pif.json"
(cd "$MOD" && "$TEST_SH" "$MOD/migrate.sh" -f "$MOD/custom.pif.json") > "$W/esc-ok.out" 2>&1
check "json \\u0041 / \\x41 escapes: not refused" sh -c '! grep -q Refusing "$1" && test -e "$2.bak" && grep -q "Advanced Settings" "$2"' - "$W/esc-ok.out" "$MOD/custom.pif.json"
if command -v dash >/dev/null 2>&1; then
    new_root
    printf '{\n  "MANUFACTURER": "Google",\n  "MODEL": "x\\\\044(touch %s/pwned-octal)",\n  "FINGERPRINT": "google/zzdev/zzdev:99/ZZ1A.250101.001/1234567:user/release-keys"\n}\n' "$W" > "$MOD/custom.pif.json"
    check "fixture holds an escaped backslash before 044" grep -qF '"x\\044(touch' "$MOD/custom.pif.json"
    (cd "$MOD" && dash "$MOD/migrate.sh" -f "$MOD/custom.pif.json") > "$W/octal.out" 2>&1
    check "json octal echo escape under dash: not executed" test ! -e "$W/pwned-octal"
else
    skip "json octal echo escape (no dash, whose echo expands \\0nnn)"
fi
json_case okcomment "  // Build Fields
  \"MODEL\": \"x\", // a note (with punctuation)
  //\"ro.build.version.security_patch\": \"2025-01-05\","
check "json word-start comments still migrate" sh -c 'test -e "$1.bak" && grep -qF "\"MODEL\": \"x\"" "$1"' - "$MOD/custom.pif.json"
check "json word-start comments: not refused" sh -c '! grep -q Refusing "$1" && test -e "$2.bak" && grep -q "Advanced Settings" "$2"' - "$W/okcomment.out" "$MOD/custom.pif.json"

# without a working awk the JSON check must refuse, not pass the file to the eval-based getter
new_root
printf '#!/bin/sh\nexit 127\n' > "$W/bin/awk"; chmod 755 "$W/bin/awk"
printf '{\n  "MANUFACTURER": "Google",\n  "MODEL": "x$(touch %s/pwned-noawk)",\n  "FINGERPRINT": "google/zzdev/zzdev:99/ZZ1A.250101.001/1234567:user/release-keys"\n}\n' "$W" > "$MOD/custom.pif.json"
cp "$MOD/custom.pif.json" "$W/orig.json"
(cd "$MOD" && "$TEST_SH" "$MOD/migrate.sh" -f "$MOD/custom.pif.json") > "$W/noawk.out" 2>&1
rc=$?
check "no awk: json not executed" test ! -e "$W/pwned-noawk"
check "no awk: refused with non-zero exit" test "$rc" -ne 0
check "no awk: refused by the awk check" has_text "$W/noawk.out" "awk is needed to check the file"
check "no awk: original unchanged" cmp -s "$MOD/custom.pif.json" "$W/orig.json"

# the JSON getter reads values as data: no eval of file content, same result on every shell
M="$ROOT/module/migrate.sh"
check "json getter has no eval" sh -c '! sed -n "/^grep_get_json() {/,/^}/p" "$1" | grep -q eval' - "$M"
check "json branches assign without eval of the value" sh -c '! grep -E "^[[:space:]]*\*\.json\).*eval" "$1" | grep -q .' - "$M"
for S in "$TEST_SH" mksh dash; do
    command -v "$S" >/dev/null 2>&1 || { skip "json escapes written literally under $S (not installed)"; continue; }
    new_root
    printf '{\n  "MANUFACTURER": "Google",\n  "MODEL": "a\\/b\\u0041\\tc\\\\d",\n  "FINGERPRINT": "google/zzdev/zzdev:99/ZZ1A.250101.001/1234567:user/release-keys",\n  "verboseLogs": "0"\n}\n' > "$MOD/custom.pif.json"
    (cd "$MOD" && "$S" "$MOD/migrate.sh" -f "$MOD/custom.pif.json") > "$W/lit.out" 2>&1
    check "json escapes written literally under $S" has_line "$MOD/custom.pif.json" '    "MODEL": "a\/b\u0041\tc\d",'
    printf 'MANUFACTURER=Google\nMODEL=a\\nb\\u0041\nFINGERPRINT=google/zzdev/zzdev:99/ZZ1A.250101.001/1234567:user/release-keys\n' > "$MOD/custom.pif.prop"
    (cd "$MOD" && "$S" "$MOD/migrate.sh" -p "$MOD/custom.pif.prop") > "$W/litp.out" 2>&1
    check "prop backslashes written literally under $S" has_line "$MOD/custom.pif.prop" 'MODEL=a\nb\u0041'
    new_root
    printf '{\n  "MANUFACTURER": "Google",\n  "MODEL": "x\\\\",\n  "FINGERPRINT": "google/zzdev/zzdev:99/ZZ1A.250101.001/1234567:user/release-keys"\n}\n' > "$MOD/custom.pif.json"
    cp "$MOD/custom.pif.json" "$W/orig.json"
    (cd "$MOD" && "$S" "$MOD/migrate.sh" -f "$MOD/custom.pif.json") > "$W/tb.out" 2>&1
    rc=$?
    check "json value ending in a backslash under $S: refused, exit 1" test "$rc" -eq 1
    check "json value ending in a backslash under $S: file unchanged" cmp -s "$MOD/custom.pif.json" "$W/orig.json"
done
