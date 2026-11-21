# customize.sh (sourced by the root manager installer) with a previous module installed.

install_module() {
    # $1: directory of the module being installed (Magisk modules_update)
    NEWMOD="$1"
    (
        ui_print() { echo "$1"; }
        MODPATH="$NEWMOD"
        cd "$NEWMOD" && . "$NEWMOD/customize.sh"
    ) > "$W/install.out" 2>&1
}

new_root
NEW="$W/data/adb/modules_update/playintegrityfork"
mkdir -p "$NEW" && cp -a "$MOD/." "$NEW/" && mkdir -p "$NEW/zygisk"
cat > "$MOD/custom.pif.prop" <<'PIF'
MANUFACTURER=Google
MODEL=Pixel Test
spoofProvider=0
PIF
for f in skipaddprop skipdelprop skipmatchdevice skippersistprop; do touch "$MOD/$f"; done
echo 'resetprop -p --delete "persist.sys.example"' > "$MOD/uninstall.sh"
mkdir -p "$MOD/system/product/app/Example"
setprop sys.boot_completed 1
install_module "$NEW"
check "install exits 0" test "$?" -eq 0
check "custom.pif.prop restored" cmp -s "$MOD/custom.pif.prop" "$NEW/custom.pif.prop"
for f in skipaddprop skipdelprop skipmatchdevice skippersistprop uninstall.sh; do
    check "$f restored" test -f "$NEW/$f"
done
check "disabled ROM apps restored" test -d "$NEW/system/product/app/Example"
check "skippersistprop runs uninstall.sh" has_line "$W/calls.log" "resetprop -p --delete persist.sys.example"

# custom.pif.json from an old release is migrated during install
new_root
NEW="$W/data/adb/modules_update/playintegrityfork"
mkdir -p "$NEW" && cp -a "$MOD/." "$NEW/" && mkdir -p "$NEW/zygisk"
cat > "$MOD/custom.pif.json" <<'PIF'
{
  "MANUFACTURER": "Google",
  "MODEL": "Pixel Test",
  "FINGERPRINT": "google/zzdev/zzdev:99/ZZ1A.250101.001/1234567:user/release-keys",
  "SECURITY_PATCH": "2025-01-05",
  "DEVICE_INITIAL_SDK_INT": "32"
}
PIF
setprop sys.boot_completed 1
install_module "$NEW"
check "custom.pif.json migrated during install" has_text "$NEW/custom.pif.json" '"spoofVendingFinger": "0"'
check "migration keeps old file as .bak" test -f "$NEW/custom.pif.json.bak"
check "migrated json derives BRAND" has_text "$NEW/custom.pif.json" '"BRAND": "google"'

# scripts-only mode
new_root
NEW="$W/data/adb/modules_update/playintegrityfork"
mkdir -p "$NEW" && cp -a "$MOD/." "$NEW/"
touch "$MOD/scripts-only-mode"
setprop sys.boot_completed 1
install_module "$NEW"
check "scripts-only marker kept" test -f "$NEW/scripts-only-mode"
check "scripts-only removes autopif4.sh" test ! -e "$NEW/autopif4.sh"
check "scripts-only description" grep -q '^description=\[Scripts-only mode\]' "$NEW/module.prop"

# app hide list (common_setup.sh during install): each existing entry is hidden at its own path, with
# nothing carried over from the entry before it. A /system/* entry after a non-/system one is hidden
# without the /system prefix, and the overlay config message is printed only for the overlay entry.
# Device paths are made under $W: the copy's "/system/*)" arm is moved to "$W/system/*)" like lib.sh
# moves /data/adb; unzip/strings are stubbed to give the overlay apk a made-up package name. A runner
# sh without [[ (dash) prints neither message, hence "at most once".
new_root
NEW="$W/data/adb/modules_update/playintegrityfork"
mkdir -p "$NEW" && cp -a "$MOD/." "$NEW/" && mkdir -p "$NEW/zygisk"
sed -i "s#^\( *\)/system/\*) ;;#\1$W/system/*) ;;#" "$NEW/common_setup.sh"
check "app list: /system arm moved under the fake root" grep -qF "$W/system/*) ;;" "$NEW/common_setup.sh"
mkdir -p "$W/product/overlay/ZzOverlay" "$W/product/overlay/config" "$W/system/app/ZzInject"
echo apk > "$W/product/overlay/ZzOverlay/ZzOverlay.apk"
echo '<overlay package="zz.overlay.pkg" priority="1" />' > "$W/product/overlay/config/config.xml"
printf '%s\n' "$W/product/overlay/ZzOverlay" "$W/system/app/ZzInject" > "$MOD/custom.app_replace_list.txt"
printf '#!/bin/sh\necho "android x zz.overlay.pkg overlay overlay"\n' > "$W/bin/unzip"
printf '#!/bin/sh\ncat\n' > "$W/bin/strings"
chmod 755 "$W/bin/unzip" "$W/bin/strings"
setprop sys.boot_completed 1
install_module "$NEW"
check "app list: non-/system entry hidden under system/" test -f "$NEW/system$W/product/overlay/ZzOverlay/.replace"
check "app list: /system entry after it hidden without a second system/" test -f "$NEW$W/system/app/ZzInject/.replace"
check "app list: overlay config entry commented out" grep -qF '<!-- overlay package="zz.overlay.pkg"' "$NEW/system$W/product/overlay/config/config.xml"
check "app list: overlay config message printed at most once" test "$(grep -c 'zz.overlay.pkg entry commented out' "$W/install.out")" -le 1

# app hide list: an overlay entry that is neither a directory nor an .apk gets no APK of its own, so
# it must not reuse the previous entry's APK and comment out that package in its own overlay config.
new_root
NEW="$W/data/adb/modules_update/playintegrityfork"
mkdir -p "$NEW" && cp -a "$MOD/." "$NEW/" && mkdir -p "$NEW/zygisk"
mkdir -p "$W/product/overlay/ZzOverlay" "$W/product/overlay/config" "$W/odm/overlay/config"
echo apk > "$W/product/overlay/ZzOverlay/ZzOverlay.apk"
echo '<overlay package="zz.overlay.pkg" priority="1" />' > "$W/product/overlay/config/config.xml"
echo txt > "$W/odm/overlay/Zz.txt"
echo '<overlay package="zz.overlay.pkg" priority="1" />' > "$W/odm/overlay/config/config.xml"
printf '%s\n' "$W/product/overlay/ZzOverlay" "$W/odm/overlay/Zz.txt" > "$MOD/custom.app_replace_list.txt"
printf '#!/bin/sh\necho "android x zz.overlay.pkg overlay overlay"\n' > "$W/bin/unzip"
printf '#!/bin/sh\ncat\n' > "$W/bin/strings"
chmod 755 "$W/bin/unzip" "$W/bin/strings"
setprop sys.boot_completed 1
install_module "$NEW"
check "app list: overlay apk entry still commented out in its config" grep -qF '<!-- overlay package="zz.overlay.pkg"' "$NEW/system$W/product/overlay/config/config.xml"
check "app list: non-apk overlay entry does not reuse the previous apk" test ! -e "$NEW/system$W/odm/overlay/config/config.xml"

# install paths across the module ID rename (playintegrityfix -> playintegrityfork)
OLDID_FILES="custom.app_replace_list.txt custom.pif.prop skipaddprop skipdelprop skipmatchdevice uninstall.sh"

# old_module: a previous playintegrityfix install of this module at $OLD with config, the new ID
# module dir $MOD gone; $NEW is the modules_update dir being installed
old_module() {
    OLD="$W/data/adb/modules/playintegrityfix"
    NEW="$W/data/adb/modules_update/playintegrityfork"
    mkdir -p "$NEW" && cp -a "$MOD/." "$NEW/" && mkdir -p "$NEW/zygisk"
    mkdir -p "$OLD" && cp -a "$MOD/." "$OLD/" && mkdir -p "$OLD/zygisk"
    rm -rf "$MOD"
    printf 'MANUFACTURER=Google\nMODEL=Pixel Old\n' > "$OLD/custom.pif.prop"
    echo /system/app/ZzOld > "$OLD/custom.app_replace_list.txt"
    for f in skipaddprop skipdelprop skipmatchdevice; do touch "$OLD/$f"; done
    printf '%s\n' "resetprop -n -p \"persist.sys.pihooks.disable.gms_props\" 'false'" \
        'resetprop -p --delete "persist.sys.pihooks.first_api_level"' > "$OLD/uninstall.sh"
    mkdir -p "$OLD/system/product/app/ZzOld"
}

# fresh install: no previous module under either ID
new_root
NEW="$W/data/adb/modules_update/playintegrityfork"
mkdir -p "$NEW" && cp -a "$MOD/." "$NEW/" && mkdir -p "$NEW/zygisk"
rm -rf "$MOD"
setprop sys.boot_completed 1
install_module "$NEW"
check "fresh install exits 0" test "$?" -eq 0
check "fresh install restores nothing" sh -c '! grep -qE "Restoring|Migrating" "$1"' - "$W/install.out"
check "fresh install marks no old module for removal" test ! -e "$W/data/adb/modules/playintegrityfix"
check "fresh install keeps zygisk" test -d "$NEW/zygisk"

# upgrade from the old ID: config carried once, old module marked for removal and left in place
new_root
old_module
setprop sys.boot_completed 1
install_module "$NEW"
check "old ID upgrade exits 0" test "$?" -eq 0
check "old ID upgrade: migration announced" grep -q 'Migrating configuration to new playintegrityfork' "$W/install.out"
for f in $OLDID_FILES; do
    check "old ID upgrade: $f carried" cmp -s "$OLD/$f" "$NEW/$f"
    check "old ID upgrade: $f restored once" test "$(grep -c "^- Restoring $f\$" "$W/install.out")" -eq 1
done
check "old ID upgrade: disabled ROM apps carried" test -d "$NEW/system/product/app/ZzOld"
check "old ID upgrade: old module marked for removal" test -f "$OLD/remove"
check "old ID upgrade: old module left for the manager" test -f "$OLD/module.prop"

# old ID upgrade, then the first boot: the manager runs the old uninstall.sh when it removes the old
# dir, and the new post-fs-data.sh runs; in either order the next boot leaves the workaround set,
# the new uninstall.sh holds each prop once and restores the values from before the old module
for order in old-first new-first; do
    new_root
    old_module
    setprop ro.aospa.version 1
    setprop persist.sys.pihooks.disable.gms_props true
    setprop persist.sys.pihooks.first_api_level ""
    setprop sys.boot_completed 1
    install_module "$NEW"
    setprop sys.boot_completed 0
    rm -rf "$MOD" && mv "$NEW" "$MOD"
    if [ "$order" = old-first ]; then
        "$TEST_SH" "$OLD/uninstall.sh" > /dev/null 2>&1; rm -rf "$OLD"
        "$TEST_SH" "$MOD/post-fs-data.sh" > "$W/out" 2>&1
    else
        "$TEST_SH" "$MOD/post-fs-data.sh" > "$W/out" 2>&1
        "$TEST_SH" "$OLD/uninstall.sh" > /dev/null 2>&1; rm -rf "$OLD"
        "$TEST_SH" "$MOD/post-fs-data.sh" > "$W/out" 2>&1
    fi
    check "old ID boot ($order): workaround prop set" test "$(prop persist.sys.pihooks.disable.gms_props)" = true
    check "old ID boot ($order): uninstall.sh holds gms_props once" test "$(grep -c 'persist.sys.pihooks.disable.gms_props' "$MOD/uninstall.sh")" -eq 1
    check "old ID boot ($order): uninstall.sh holds first_api_level once" test "$(grep -c 'persist.sys.pihooks.first_api_level' "$MOD/uninstall.sh")" -eq 1
    "$TEST_SH" "$MOD/uninstall.sh" > /dev/null 2>&1
    check "old ID boot ($order): uninstall restores the original value" test "$(prop persist.sys.pihooks.disable.gms_props)" = false
    check "old ID boot ($order): uninstall deletes the created prop" sh -c '! grep -q "^persist.sys.pihooks.first_api_level=" "$1"' - "$W/props"
done

# scripts-only mode with a full old ID install, requested by the marker in either module dir (README:
# create scripts-only-mode in the module dir, then reflash): the old module's uninstall.sh runs, none of
# its config reaches the stripped module, migrate.sh is not called and the old module is marked for removal
for trig in old new; do
    new_root
    old_module
    printf '{\n  "MODEL": "Pixel Old"\n}\n' > "$OLD/custom.pif.json"
    setprop persist.sys.pihooks.disable.gms_props true
    setprop persist.sys.pihooks.first_api_level ""
    if [ "$trig" = old ]; then
        touch "$OLD/scripts-only-mode"
    else
        mkdir -p "$MOD" && touch "$MOD/scripts-only-mode"
    fi
    setprop sys.boot_completed 1
    install_module "$NEW"
    S="scripts-only ($trig ID marker) over the old ID"
    check "$S: marker set" test -f "$NEW/scripts-only-mode"
    check "$S: zygisk removed" test ! -e "$NEW/zygisk"
    check "$S: description" grep -q '^description=\[Scripts-only mode\]' "$NEW/module.prop"
    for f in custom.pif.prop custom.pif.json custom.app_replace_list.txt uninstall.sh system; do
        check "$S: old $f not carried" test ! -e "$NEW/$f"
    done
    check "$S: removed migrate.sh not called" sh -c '! grep -q "migrate.sh" "$1"' - "$W/install.out"
    check "$S: old uninstall.sh restores the original value" test "$(prop persist.sys.pihooks.disable.gms_props)" = false
    check "$S: old uninstall.sh deletes the created prop" sh -c '! grep -q "^persist.sys.pihooks.first_api_level=" "$1"' - "$W/props"
    check "$S: old module marked for removal" test -f "$OLD/remove"
    check "$S: skipdelprop carried as in a same-ID update" test -f "$NEW/skipdelprop"
done

# upgrade of an old ID install that is in scripts-only mode (no migrate.sh there): its skip markers are
# carried like in a same-ID update, and the scripts-only choice moves to the new module
new_root
OLD="$W/data/adb/modules/playintegrityfix"
NEW="$W/data/adb/modules_update/playintegrityfork"
mkdir -p "$NEW" && cp -a "$MOD/." "$NEW/" && mkdir -p "$NEW/zygisk"
mkdir -p "$OLD" && for f in module.prop common_func.sh post-fs-data.sh service.sh; do cp "$MOD/$f" "$OLD/"; done
rm -rf "$MOD"
touch "$OLD/scripts-only-mode" "$OLD/skipdelprop" "$OLD/skipaddprop"
setprop sys.boot_completed 1
install_module "$NEW"
S="old ID scripts-only install"
check "$S: still scripts-only" test -f "$NEW/scripts-only-mode"
check "$S: skipdelprop carried" test -f "$NEW/skipdelprop"
check "$S: skipaddprop carried" test -f "$NEW/skipaddprop"
check "$S: old module marked for removal" test -f "$OLD/remove"

# README's old opt-in left a marker-only old ID dir: the first install honours it, and once the user
# removes the new module's marker a reflash installs the full module again
new_root
OLD="$W/data/adb/modules/playintegrityfix"
NEW="$W/data/adb/modules_update/playintegrityfork"
mkdir -p "$NEW" && cp -a "$MOD/." "$NEW/" && mkdir -p "$NEW/zygisk"
rm -rf "$MOD"
mkdir -p "$OLD" && touch "$OLD/scripts-only-mode"
setprop sys.boot_completed 1
install_module "$NEW"
S="marker-only old ID dir"
check "$S: first install is scripts-only" test -f "$NEW/scripts-only-mode"
mv "$NEW" "$MOD" && rm -f "$MOD/scripts-only-mode"
mkdir -p "$NEW" && copy_module "$NEW" && mkdir -p "$NEW/zygisk"
install_module "$NEW"
check "$S: reflash without the new marker installs the full module" test -d "$NEW/zygisk" -a ! -f "$NEW/scripts-only-mode"

# both IDs installed (old module kept past a boot): the live new ID config wins, nothing is restored
# twice and a marker the user removed from the new module does not come back from the old one
new_root
OLD="$W/data/adb/modules/playintegrityfix"
NEW="$W/data/adb/modules_update/playintegrityfork"
mkdir -p "$NEW" && cp -a "$MOD/." "$NEW/" && mkdir -p "$NEW/zygisk"
mkdir -p "$OLD" && cp -a "$MOD/." "$OLD/" && mkdir -p "$OLD/zygisk"
printf 'MANUFACTURER=Google\nMODEL=Pixel New\n' > "$MOD/custom.pif.prop"
printf 'MANUFACTURER=Google\nMODEL=Pixel Old\n' > "$OLD/custom.pif.prop"
touch "$OLD/skipdelprop"
setprop sys.boot_completed 1
install_module "$NEW"
S="both IDs installed"
check "$S: new ID config kept" has_line "$NEW/custom.pif.prop" "MODEL=Pixel New"
check "$S: custom.pif.prop restored once" test "$(grep -c '^- Restoring custom.pif.prop$' "$W/install.out")" -eq 1
check "$S: marker absent from the new module not taken from the old" test ! -e "$NEW/skipdelprop"
check "$S: old module marked for removal" test -f "$OLD/remove"

# a new ID dir holding only module.prop (a manager's entry for an install still pending a reboot) is no
# installed module: the old ID config is still migrated
new_root
old_module
mkdir -p "$MOD" && cp "$NEW/module.prop" "$MOD/"
setprop sys.boot_completed 1
install_module "$NEW"
check "pending new ID entry: old config migrated" cmp -s "$OLD/custom.pif.prop" "$NEW/custom.pif.prop"
