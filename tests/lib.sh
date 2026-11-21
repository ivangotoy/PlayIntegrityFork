# Shared helpers for tests/run.sh (sourced, POSIX sh).
#
# Module scripts hard-code /data/adb, /data/data, /data/system, /sys/fs/selinux and
# /dev/__properties__. Each case copies module/ into a fresh fake root and rewrites
# those absolute paths to point inside it; nothing else in the scripts is changed.

PASS=0
FAIL=0
SKIP=0

ok() { PASS=$((PASS + 1)); echo "ok   - $CASE: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $CASE: $*"; }
skip() { SKIP=$((SKIP + 1)); echo "skip - $CASE: $*"; }

check() {
    _msg="$1"; shift
    if "$@"; then ok "$_msg"; else bad "$_msg"; fi
}

has_line() { grep -qxF -- "$2" "$1" 2>/dev/null; }
has_text() { grep -qF -- "$2" "$1" 2>/dev/null; }

# new_root: fresh fake device root in $W, module copied to $MOD, stubs in $W/bin
new_root() {
    W="$(mktemp -d "$WORK/case.XXXXXX")"
    W="$(cd -P "$W" && pwd)"
    MOD="$W/data/adb/modules/playintegrityfork"
    mkdir -p "$W/bin" "$MOD" "$W/data/adb/magisk" "$W/data/data/com.google.android.gms" \
        "$W/data/system" "$W/sys/fs/selinux" "$W/dev"
    copy_module "$MOD"
    : > "$W/props"
    : > "$W/calls.log"
    write_stubs
    PATH="$W/bin:$BASE_PATH"
    STUB_PROPS="$W/props"
    STUB_LOG="$W/calls.log"
    export PATH STUB_PROPS STUB_LOG
}

# copy_module <dest>: module/ files with device paths moved into $W; the gitignored build
# outputs (zygisk/, classes.dex, pif.json) left by assembleRelease are not copied
copy_module() {
    (cd "$ROOT/module" && find . -type d) | while read -r d; do
        case "$d" in ./zygisk|./zygisk/*) continue ;; esac
        mkdir -p "$1/$d"
    done
    (cd "$ROOT/module" && find . -type f) | while read -r f; do
        case "$f" in
            ./zygisk/*|./classes.dex|./pif.json) ;;
            *.sh|*/update-binary)
                sed -e "s#/data/adb#$W/data/adb#g" -e "s#/data/data/#$W/data/data/#g" \
                    -e "s#/data/system/#$W/data/system/#g" -e "s#/sys/fs/selinux#$W/sys/fs/selinux#g" \
                    -e "s#/dev/__properties__#$W/dev/__properties__#g" \
                    "$ROOT/module/$f" > "$1/$f" ;;
            *) cp "$ROOT/module/$f" "$1/$f" ;;
        esac
    done
}

# setprop <name> <value>: preset a property in the fake property store
setprop() { echo "$1=$2" >> "$W/props"; }
prop() { awk -v n="$1" 'index($0, n "=") == 1 { v = substr($0, length(n) + 2); f = 1 } END { if (f) print v; exit !f }' "$W/props"; }

write_stubs() {
    B="$W/bin"
    cat > "$B/resetprop" <<'EOF'
#!/bin/sh
echo "resetprop $*" >> "$STUB_LOG"
get() { awk -v n="$1" 'index($0, n "=") == 1 { v = substr($0, length(n) + 2); f = 1 } END { if (f) print v; exit !f }' "$STUB_PROPS"; }
del() { awk -v n="$1" 'index($0, n "=") != 1' "$STUB_PROPS" > "$STUB_PROPS.new"; mv "$STUB_PROPS.new" "$STUB_PROPS"; }
put() { del "$1"; echo "$1=$2" >> "$STUB_PROPS"; }
case "$1" in
    "") sed 's/^\([^=]*\)=\(.*\)$/[\1]: [\2]/' "$STUB_PROPS"; exit 0 ;;
    --compact|-c) exit 0 ;;
    -Z) echo "u:object_r:test_prop:s0"; exit 0 ;;
    --delete) del "$2"; exit 0 ;;
    -n) shift; [ "$1" = -p ] && shift
        if [ "$1" = --delete ]; then del "$2"; else put "$1" "$2"; fi; exit 0 ;;
    -p) shift; if [ "$1" = --delete ]; then del "$2"; else put "$1" "$2"; fi; exit 0 ;;
esac
if [ "$#" -ge 2 ]; then put "$1" "$2"; exit 0; fi
get "$1"
EOF
    cat > "$B/getprop" <<'EOF'
#!/bin/sh
awk -v n="$1" 'index($0, n "=") == 1 { print substr($0, length(n) + 2); exit }' "$STUB_PROPS"
EOF
    cat > "$B/magisk" <<'EOF'
#!/bin/sh
echo "magisk $*" >> "$STUB_LOG"
[ "$1 $2" = "--denylist status" ] && exit "${STUB_DENYLIST_RC:-1}"
exit 0
EOF
    cat > "$B/toybox" <<'EOF'
#!/bin/sh
shift
exec cat "$@"
EOF
    cat > "$B/whoami" <<'EOF'
#!/bin/sh
echo root
EOF
    for c in killall pm am setfattr ksud su; do
        printf '#!/bin/sh\necho "%s $*" >> "$STUB_LOG"\nexit 0\n' "$c" > "$B/$c"
    done
    cat > "$B/mknod" <<'EOF'
#!/bin/sh
echo "mknod $*" >> "$STUB_LOG"
: > "$1"
EOF
    chmod 755 "$B"/*
}

# write_fetch_stubs <fixture dir>: offline wget/nc serving canned responses
write_fetch_stubs() {
    FIX="$1"
    cat > "$W/bin/wget" <<EOF
#!/bin/sh
FIX="$FIX"
EOF
    cat >> "$W/bin/wget" <<'EOF'
echo "wget $*" >> "$STUB_LOG"
out=""; log=""; spider=""
while [ "$#" -gt 1 ]; do
    case "$1" in
        -O) out="$2"; shift ;;
        -o) log="$2"; shift ;;
        -T|--header) shift ;;
        --spider) spider=1 ;;
    esac
    shift
done
url="$1"
if [ -n "$spider" ]; then
    printf '  HTTP/1.1 200 OK\n  Last-Modified: Tue, 07 Jan 2025 10:00:00 GMT\n' > "$log"
    exit 0
fi
case "$url" in
    https://developer.android.com/about/versions) f=versions.html ;;
    https://developer.android.com/about/versions/99) f=latest.html ;;
    https://developer.android.com/about/versions/99/download) f=fi.html ;;
    https://developer.android.com/about/versions/99/download-ota) f=ota.html ;;
    https://flash.android.com/) f=flash.html ;;
    https://content-flashstation-pa.googleapis.com/v1/builds\?product=*) f="station-${url##*product=}"; f="${f%%&*}.json" ;;
    https://source.android.com/docs/security/bulletin/pixel) f=secbull.html ;;
    *) echo "wget stub: no fixture for $url" >&2; exit 1 ;;
esac
[ -f "$FIX/$f" ] || { echo "wget stub: missing $FIX/$f" >&2; exit 1; }
cp "$FIX/$f" "$out"
EOF
    cat > "$W/bin/nc" <<'EOF'
#!/bin/sh
echo "nc $*" >> "$STUB_LOG"
cat > /dev/null
printf 'HTTP/1.1 200 OK\r\nLast-Modified: Tue, 07 Jan 2025 10:00:00 GMT\r\n\r\n'
EOF
    chmod 755 "$W/bin/wget" "$W/bin/nc"
    # autopif4 falls back to a busybox date when the system date lacks -D (GNU date)
    REAL_DATE="$(command -v date)"
    cat > "$W/data/adb/magisk/busybox" <<EOF
#!/bin/sh
REAL_DATE="$REAL_DATE"
EOF
    cat >> "$W/data/adb/magisk/busybox" <<'EOF'
[ "$1" = date ] || exit 1
shift
fmt=""; val=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -D) fmt="$2"; shift 2 ;;
        -d) val="$2"; shift 2 ;;
        *) break ;;
    esac
done
[ "$fmt" = "%s" ] && val="@$val"
if [ -n "$val" ]; then exec "$REAL_DATE" -u -d "$val" "$@"; fi
exec "$REAL_DATE" -u "$@"
EOF
    chmod 755 "$W/data/adb/magisk/busybox"
}
