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
# Only test that the files exist: whether unzip kept the execute bit depends
# on the manager, and permissions are set just below anyway.
for b in unbound unbound-control unbound-anchor curl; do
    [ -f "$MODPATH/bin/$ABI/$b" ] || abort "! This zip has no $b binary for $ABI"
done

ui_print "- Installing Unbound for $ABI"
mv "$MODPATH/bin/$ABI"/* "$MODPATH/bin/"
rm -rf "$MODPATH/bin/arm64-v8a" "$MODPATH/bin/armeabi-v7a" "$MODPATH/bin/x86_64"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
for f in ctl.sh service.sh action.sh uninstall.sh lib/notify.sh; do
    set_perm "$MODPATH/$f" 0 0 0755
done

UNBOUND_MODDIR="$MODPATH" UNBOUND_NO_BUSYBOX_REEXEC=1 sh "$MODPATH/ctl.sh" setup \
    || abort "! Could not prepare /data/adb/unbound"

# --- How Unbound resolves names ---------------------------------------------------
# Vol+ shows the next option, Vol- chooses it. Nothing pressed for 10 s keeps
# the default: recursive on a new install, the current choice on an update.

_ctl() { UNBOUND_MODDIR="$MODPATH" UNBOUND_NO_BUSYBOX_REEXEC=1 sh "$MODPATH/ctl.sh" "$@"; }

resolver_name() {
    case "$1" in
        recursive) echo "Recursive (on this phone only)" ;;
        cloudflare) echo "Cloudflare (encrypted)" ;;
        quad9) echo "Quad9 (encrypted, blocks malware)" ;;
        controld) echo "ControlD free (encrypted)" ;;
        custom) echo "Custom servers (encrypted)" ;;
        *) echo "$1" ;;
    esac
}

# vol_key SECONDS: prints "up" or "down" for a volume key press, or nothing
# when no key was pressed in time.
vol_key() {
    _end=$(( $(date +%s) + $1 ))
    while [ "$(date +%s)" -lt "$_end" ]; do
        _ev="$(timeout 1 getevent -lqc 1 2>/dev/null)"
        case "$_ev" in
            *KEY_VOLUMEUP*DOWN*) echo up; return 0 ;;
            *KEY_VOLUMEDOWN*DOWN*) echo down; return 0 ;;
        esac
    done
}

# nth N WORDS...: the Nth word.
nth() {
    _n="$1"; shift
    for _w in "$@"; do
        _n=$((_n - 1))
        [ "$_n" = 0 ] && { echo "$_w"; return 0; }
    done
}

choose_resolver() {
    _wait="${UNBOUND_INSTALL_TIMEOUT:-10}"
    # The first RESOLVER in the JSON is the current value (defaults follow).
    _current="$(_ctl settings 2>/dev/null | grep -o '"RESOLVER":"[a-z0-9]*"' | head -n 1 | cut -d'"' -f4)"
    _default="${_current:-recursive}"
    if ! command -v getevent >/dev/null 2>&1; then
        ui_print "- Resolver: $(resolver_name "$_default") (change it in the WebUI)"
        return 0
    fi
    _options="recursive cloudflare quad9 controld"
    case " $_options " in *" $_default "*) ;; *) _options="$_default $_options" ;; esac
    ui_print "- How should Unbound resolve names?"
    ui_print "    Vol+ = next option, Vol- = choose"
    ui_print "    No key for ${_wait}s keeps: $(resolver_name "$_default")"
    _count=0
    for _o in $_options; do _count=$((_count + 1)); done
    # Start the list at the default so Vol- right away keeps it.
    _i=1
    for _o in $_options; do [ "$_o" = "$_default" ] && break; _i=$((_i + 1)); done
    while :; do
        _shown="$(nth "$_i" $_options)"
        ui_print "    > $(resolver_name "$_shown")"
        case "$(vol_key "$_wait")" in
            up) _i=$(( _i % _count + 1 )) ;;
            down) _choice="$_shown"; break ;;
            *) _choice=""; break ;;
        esac
    done
    if [ -z "$_choice" ]; then
        ui_print "- Keeping $(resolver_name "$_default")"
        return 0
    fi
    if [ "$_choice" != "$_default" ]; then
        _ctl settings-apply "RESOLVER=$_choice" >/dev/null 2>&1 \
            || ui_print "! Could not save the choice; change it in the WebUI"
    fi
    ui_print "- Resolver: $(resolver_name "$_choice")"
}

choose_resolver

ui_print "- Settings and blocklists live in /data/adb/unbound"
ui_print "- After reboot all DNS goes to Unbound on this phone."
ui_print "  Private DNS is switched off while the module runs"
ui_print "  (it would bypass Unbound) and restored on removal."
ui_print "- Add blocklists and change settings in the module's WebUI."
