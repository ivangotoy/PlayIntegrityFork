# autopif4.sh / action.sh offline: canned made-up pages, stub wget/nc, fake root.

run_autopif() {
    # remaining args are passed to autopif4.sh
    (cd "$MOD" && USER=root HOME=/ "$TEST_SH" "$MOD/autopif4.sh" "$@") > "$W/autopif.out" 2>&1
}

# first run: no existing config, Tricky Store present
new_root
write_fetch_stubs "$ROOT/tests/fixtures/autopif4"
setprop ro.product.device otherdev
mkdir -p "$W/data/adb/tricky_store"
echo "all=2024-01-01" > "$W/data/adb/tricky_store/security_patch.txt"
run_autopif -m
check "autopif4 exits 0" test "$?" -eq 0
C="$MOD/custom.pif.prop"
check "custom.pif.prop installed" test -f "$C"
check "MODEL from device list" has_line "$C" "MODEL=Pixel Test"
check "FINGERPRINT assembled" has_line "$C" "FINGERPRINT=google/zzdev_beta/zzdev:CANARY/ZZ1A.250101.001/1234567:user/release-keys"
check "PRODUCT set" has_line "$C" "PRODUCT=zzdev_beta"
check "SECURITY_PATCH from bulletin" has_line "$C" "SECURITY_PATCH=2025-01-05"
check "first API level default" has_line "$C" "DEVICE_INITIAL_SDK_INT=37"
check "strong config: spoofProvider=0" has_line "$C" "spoofProvider=0"
check "Tricky Store present: security_patch not commented" has_line "$C" "ro.build.version.security_patch=2025-01-05"
if date --version 2>/dev/null | grep -q GNU || { date -D '%a, %d %b %Y %H:%M:%S %Z' -d "Tue, 07 Jan 2025 10:00:00 GMT" >/dev/null 2>&1 && date -D '%s' -d 86400 >/dev/null 2>&1; }; then
    check "release date comment" has_text "$C" "Canary Released: 2025-01-07"
    check "expiry date comment" has_text "$C" "Estimated Expiry: 2025-02-18"
else
    skip "release/expiry dates (this libc's strptime lacks %Z or %s; bionic has both)"
fi
check "Tricky Store security_patch.txt updated" has_line "$W/data/adb/tricky_store/security_patch.txt" "all=2025-01-05"
check "killpi.sh run" has_line "$W/calls.log" "killall -v com.google.android.gms.unstable"
check "downloads time out" sh -c '! grep "^wget" "$1" | grep -v -- "-T 10" | grep -q .' - "$W/calls.log"

# second run keeps existing advanced settings and backs up the old file
cp "$C" "$W/first.prop"
sed -i 's/^spoofSignature=0$/spoofSignature=1/' "$C"
run_autopif
check "second run exits 0" test "$?" -eq 0
check "old config backed up" test -f "$C.bak"
check "existing spoofSignature kept" has_line "$C" "spoofSignature=1"

# existing advanced settings are carried over as data, never run (payload only touches $W)
new_root
write_fetch_stubs "$ROOT/tests/fixtures/autopif4"
cat > "$MOD/custom.pif.prop" <<PIF
MODEL=Pixel Old
spoofSignature=1;touch $W/pwned-adv
spoofVendingFinger=google/zzother/zzother:98/ZZ0A.240101.001/7654321:user/release-keys,test-keys
verboseLogs=3
PIF
run_autopif
check "advanced setting value is not executed" test ! -e "$W/pwned-adv"
check "unsafe advanced setting value not carried" has_line "$MOD/custom.pif.prop" "spoofSignature=0"
check "fingerprint spoofVendingFinger with comma tags carried" has_line "$MOD/custom.pif.prop" "spoofVendingFinger=google/zzother/zzother:98/ZZ0A.240101.001/7654321:user/release-keys,test-keys"
check "verboseLogs carried" has_line "$MOD/custom.pif.prop" "verboseLogs=3"

# downloaded values with characters that break the config or sed sinks are refused
new_root
mkdir -p "$W/fix" && cp "$ROOT"/tests/fixtures/autopif4/* "$W/fix/"
sed -i 's;<td>2025-01-05</td>;<td>2025-01-05\&x/y</td>;' "$W/fix/secbull.html"
write_fetch_stubs "$W/fix"
mkdir -p "$W/data/adb/tricky_store"
echo "all=2024-01-01" > "$W/data/adb/tricky_store/security_patch.txt"
run_autopif
check "unsafe downloaded value: autopif4 fails" test "$?" -ne 0
check "unsafe downloaded value: no config installed" test ! -e "$MOD/custom.pif.prop"
check "unsafe downloaded value: Tricky Store file untouched" has_line "$W/data/adb/tricky_store/security_patch.txt" "all=2024-01-01"

new_root
mkdir -p "$W/fix" && cp "$ROOT"/tests/fixtures/autopif4/* "$W/fix/"
sed -i "s;<td>Pixel Test</td>;<td>Pixel \\\$(touch $W/pwned-dl)</td>;" "$W/fix/fi.html"
write_fetch_stubs "$W/fix"
run_autopif
check "shell syntax in downloaded MODEL: autopif4 fails" test "$?" -ne 0
check "shell syntax in downloaded MODEL: no config installed" test ! -e "$MOD/custom.pif.prop"

# a bulletin page with CRLF line endings still yields a clean SECURITY_PATCH
new_root
mkdir -p "$W/fix" && cp "$ROOT"/tests/fixtures/autopif4/* "$W/fix/"
sed -i 's/$/\r/' "$W/fix/secbull.html"
write_fetch_stubs "$W/fix"
run_autopif
check "CRLF bulletin: autopif4 exits 0" test "$?" -eq 0
check "CRLF bulletin: clean SECURITY_PATCH" has_line "$MOD/custom.pif.prop" "SECURITY_PATCH=2025-01-05"

# action.sh runs autopif4 with device matching unless skipmatchdevice exists
new_root
write_fetch_stubs "$ROOT/tests/fixtures/autopif4"
setprop ro.product.device zzdev
setprop ro.product.model "Pixel Test Local"
(cd "$MOD" && USER=root HOME=/ "$TEST_SH" "$MOD/action.sh") > "$W/action.out" 2>&1
check "action.sh exits 0" test "$?" -eq 0
check "action.sh matched device model" has_line "$MOD/custom.pif.prop" "MODEL=Pixel Test Local"
check "action.sh reports done" has_text "$W/action.out" "Done!"

# killpi.sh needs root
new_root
printf "#!/bin/sh\necho shell\n" > "$W/bin/whoami"
USER=shell "$TEST_SH" "$MOD/killpi.sh" > "$W/k.out" 2>&1
check "killpi.sh refuses non-root" test "$?" -eq 1
