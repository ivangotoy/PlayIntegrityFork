# post-fs-data.sh, service.sh and common_func.sh/common_setup.sh at boot time.

# post-fs-data.sh, Zygisk mode, Magisk DenyList enforcing, PropImitationHooks ROM
new_root
mkdir -p "$MOD/zygisk"
setprop sys.boot_completed 0
setprop ro.debuggable 1
setprop ro.secure 0
setprop ro.build.tags test-keys
setprop ro.system.build.type userdebug
setprop ro.boot.verifiedbooterror 1
setprop ro.aospa.version 1
setprop persist.sys.pihooks.disable.gms_props false
STUB_DENYLIST_RC=0 "$TEST_SH" "$MOD/post-fs-data.sh" > "$W/out" 2>&1
check "post-fs-data.sh exits 0" test "$?" -eq 0
check "ro.debuggable reset to 0" test "$(prop ro.debuggable)" = 0
check "ro.secure reset to 1" test "$(prop ro.secure)" = 1
check "ro.build.tags reset" test "$(prop ro.build.tags)" = release-keys
check "ro.system.build.type reset" test "$(prop ro.system.build.type)" = user
check "ro.boot.verifiedbooterror deleted" sh -c '! grep -q "^ro.boot.verifiedbooterror=" "$1"' - "$W/props"
check "missing ro.board.first_api_level added empty" has_line "$W/props" "ro.board.first_api_level="
check "absent prop not created by resetprop_if_diff" sh -c '! grep -q "^ro.warranty_bit=" "$1"' - "$W/props"
check "GMS removed from DenyList" has_line "$W/calls.log" "magisk --denylist rm com.google.android.gms"
check "persist pihooks prop created" has_line "$W/props" "persist.sys.pihooks.first_api_level="
check "uninstall.sh restores changed persist prop" has_line "$MOD/uninstall.sh" "resetprop -n -p \"persist.sys.pihooks.disable.gms_props\" 'false'"
check "uninstall.sh deletes created persist prop" has_line "$MOD/uninstall.sh" 'resetprop -p --delete "persist.sys.pihooks.first_api_level"'
n1="$(wc -l < "$MOD/uninstall.sh")"
"$TEST_SH" "$MOD/post-fs-data.sh" > "$W/out2" 2>&1
check "second boot adds no duplicate uninstall.sh entries" test "$(wc -l < "$MOD/uninstall.sh")" -eq "$n1"

# common_func.sh: a current property value is written into uninstall.sh as data, never as shell code
new_root
mkdir -p "$MOD/zygisk"
setprop ro.aospa.version 1
ODD="a\"b\$(touch $W/pwned-uninst)c'd \`x\`"
setprop persist.sys.pihooks.disable.gms_props "$ODD"
"$TEST_SH" "$MOD/post-fs-data.sh" > "$W/out" 2>&1
check "odd prop value: post-fs-data.sh ran nothing from it" test ! -e "$W/pwned-uninst"
"$TEST_SH" "$MOD/uninstall.sh" > "$W/out-uninst" 2>&1
check "odd prop value: uninstall.sh runs no code from it" test ! -e "$W/pwned-uninst"
check "odd prop value: uninstall.sh restores it byte for byte" test "$(prop persist.sys.pihooks.disable.gms_props)" = "$ODD"

# post-fs-data.sh, skip marker files
new_root
mkdir -p "$MOD/zygisk"
touch "$MOD/skipdelprop" "$MOD/skipaddprop"
setprop ro.boot.verifiedbooterror 1
"$TEST_SH" "$MOD/post-fs-data.sh" > "$W/out" 2>&1
check "skipdelprop keeps ro.boot.verifiedbooterror" has_line "$W/props" "ro.boot.verifiedbooterror=1"
check "skipaddprop skips ro.board.first_api_level" sh -c '! grep -q "^ro.board.first_api_level=" "$1"' - "$W/props"

# post-fs-data.sh, skippersistprop without an uninstall.sh
new_root
mkdir -p "$MOD/zygisk"
touch "$MOD/skippersistprop"
setprop ro.aospa.version 1
"$TEST_SH" "$MOD/post-fs-data.sh" > "$W/out" 2>&1
check "skippersistprop sets no persist props" sh -c '! grep -q "^persist.sys" "$1"' - "$W/props"
check "skippersistprop without uninstall.sh runs nothing" sh -c '! grep -q "uninstall.sh" "$1"' - "$W/out"

# post-fs-data.sh, scripts-only mode adds DroidGuard to the DenyList
new_root
"$TEST_SH" "$MOD/post-fs-data.sh" > "$W/out" 2>&1
check "scripts-only mode adds DenyList entries" has_line "$W/calls.log" "magisk --denylist add com.google.android.gms com.google.android.gms.unstable"

# service.sh returns at once, late props wait for boot_completed
new_root
setprop sys.boot_completed 0
setprop ro.boot.mode recovery
setprop ro.boot.selinux permissive
setprop ro.build.selinux 1
setprop ro.boot.verifiedbootstate orange
echo 0 > "$W/sys/fs/selinux/enforce"
echo x > "$W/sys/fs/selinux/policy"
chmod 644 "$W/sys/fs/selinux/enforce" "$W/sys/fs/selinux/policy"
"$TEST_SH" "$MOD/service.sh" > "$W/out" 2>&1 &
SVC=$!
i=0; while kill -0 "$SVC" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
check "service.sh returns without waiting for boot" sh -c '! kill -0 "$1" 2>/dev/null' - "$SVC"
check "ro.boot.mode recovery replaced" test "$(prop ro.boot.mode)" = unknown
check "ro.boot.selinux reset" test "$(prop ro.boot.selinux)" = enforcing
check "ro.build.selinux deleted" sh -c '! grep -q "^ro.build.selinux=" "$1"' - "$W/props"
check "selinux enforce node hidden" test "$(ls -l "$W/sys/fs/selinux/enforce" | cut -c1-10)" = "-rw-r-----"
check "late prop untouched before boot_completed" test "$(prop ro.boot.verifiedbootstate)" = orange
sed -i 's/^sys.boot_completed=0$/sys.boot_completed=1/' "$W/props"
i=0; while ! grep -q -- "--compact" "$W/calls.log" && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
check "late props set after boot_completed" test "$(prop ro.boot.verifiedbootstate)" = green
check "property area compacted" grep -q -- "resetprop --compact" "$W/calls.log"
command -v pkill >/dev/null 2>&1 && pkill -f "$W/" 2>/dev/null
