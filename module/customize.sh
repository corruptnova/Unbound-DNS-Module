# Sourced by the KernelSU / APatch / Magisk installer.
# shellcheck shell=sh disable=SC2034
SKIPUNZIP=0

if [ "${API:-0}" -lt 26 ]; then
    abort "! Android 8.0 (API 26) or newer is required"
fi

case "$ARCH" in
    arm64) ABI=arm64-v8a ;;
    arm)   ABI=armeabi-v7a ;;
    x64)   ABI=x86_64 ;;
    *)     abort "! Unsupported CPU architecture: $ARCH" ;;
esac
[ -x "$MODPATH/bin/$ABI/unbound" ] || abort "! This zip has no binaries for $ABI"

ui_print "- Installing Unbound for $ABI"
mv "$MODPATH/bin/$ABI"/* "$MODPATH/bin/"
rm -rf "$MODPATH/bin/arm64-v8a" "$MODPATH/bin/armeabi-v7a" "$MODPATH/bin/x86_64"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
for f in ctl.sh service.sh action.sh uninstall.sh; do
    set_perm "$MODPATH/$f" 0 0 0755
done

UNBOUND_MODDIR="$MODPATH" UNBOUND_NO_BUSYBOX_REEXEC=1 sh "$MODPATH/ctl.sh" setup \
    || abort "! Could not prepare /data/adb/unbound"

ui_print "- Settings and blocklists live in /data/adb/unbound"
ui_print "- After reboot all DNS goes to Unbound on this phone."
ui_print "  Private DNS is switched off while the module runs"
ui_print "  (it would bypass Unbound) and restored on removal."
ui_print "- Add blocklists from the module's WebUI."
