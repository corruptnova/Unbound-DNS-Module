#!/system/bin/sh
# Run by the root manager when the module is removed (usually during boot).
MODDIR="${0%/*}"
DATA=/data/adb/unbound

sh "$MODDIR/ctl.sh" stop >/dev/null 2>&1

# Private DNS can only be restored once Android has started.
mode="$(sed -n 's/^PRIVATE_DNS_SAVED=//p' "$DATA/settings.conf" 2>/dev/null | tail -n 1)"
spec="$(sed -n 's/^PRIVATE_DNS_SAVED_SPEC=//p' "$DATA/settings.conf" 2>/dev/null | tail -n 1)"
rm -rf "$DATA"

if [ -n "$mode" ]; then
    (
        until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 5; done
        [ -n "$spec" ] && settings put global private_dns_specifier "$spec"
        if [ "$mode" = null ]; then
            settings delete global private_dns_mode
        else
            settings put global private_dns_mode "$mode"
        fi
    ) >/dev/null 2>&1 &
fi
