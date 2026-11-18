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
for f in skipdelprop skipmatchdevice skippersistprop; do touch "$MOD/$f"; done
echo 'resetprop -p --delete "persist.sys.example"' > "$MOD/uninstall.sh"
mkdir -p "$MOD/system/product/app/Example"
setprop sys.boot_completed 1
install_module "$NEW"
check "install exits 0" test "$?" -eq 0
check "custom.pif.prop restored" cmp -s "$MOD/custom.pif.prop" "$NEW/custom.pif.prop"
for f in skipdelprop skipmatchdevice skippersistprop uninstall.sh; do
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
