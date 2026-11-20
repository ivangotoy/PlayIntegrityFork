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
NEW="$W/data/adb/modules_update/playintegrityfix"
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
NEW="$W/data/adb/modules_update/playintegrityfix"
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
NEW="$W/data/adb/modules_update/playintegrityfix"
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
NEW="$W/data/adb/modules_update/playintegrityfix"
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
NEW="$W/data/adb/modules_update/playintegrityfix"
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
