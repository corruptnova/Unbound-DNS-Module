#!/bin/sh
# customize.sh / uninstall.sh as the root manager runs them.
. "${TESTS_DIR:-$(dirname "$0")}/lib.sh"

export UNBOUND_DATA="$TMP/data" UNBOUND_NO_BUSYBOX_REEXEC=1 UNBOUND_INSTALL_TIMEOUT=2
export STUB_STATE="$TMP/state" PATH="$TESTS_DIR/stubs:$PATH"
mkdir -p "$STUB_STATE"

# Minimal stand-ins for the installer's helper functions.
ui_print() { echo "$1" >> "$TMP/ui.log"; }
abort() { echo "ABORT: $1" >> "$TMP/ui.log"; exit 1; }
set_perm() { chmod "$4" "$1"; }
set_perm_recursive() { find "$1" -type d -exec chmod "$4" {} +; find "$1" -type f -exec chmod "$5" {} +; }

stage() {
    MODPATH="$TMP/modpath"
    rm -rf "$MODPATH"; cp -R "$REPO_DIR/module" "$MODPATH"
    for abi in arm64-v8a armeabi-v7a x86_64; do
        mkdir -p "$MODPATH/bin/$abi"
        for b in unbound unbound-control unbound-anchor curl; do
            printf '#!/bin/sh\necho %s-%s\n' "$abi" "$b" > "$MODPATH/bin/$abi/$b"
            # Some managers' unzip drops the execute bit (seen with FinaSU).
            chmod 0644 "$MODPATH/bin/$abi/$b"
        done
    done
}

stage
ARCH=arm64 API=34
( . "$MODPATH/customize.sh" ) && pass || fail "customize.sh arm64"
assert_eq "arm64 binary selected" "arm64-v8a-unbound" "$("$MODPATH/bin/unbound")"
[ -d "$MODPATH/bin/x86_64" ] && fail "other ABIs removed" || pass
[ -x "$MODPATH/ctl.sh" ] && pass || fail "ctl.sh executable"
[ -f "$UNBOUND_DATA/unbound.conf" ] && pass || fail "data dir prepared"

stage
ARCH=x64 API=30
( . "$MODPATH/customize.sh" ) && pass || fail "customize.sh x64"
assert_eq "x86_64 binary selected" "x86_64-curl" "$("$MODPATH/bin/curl")"

stage
ARCH=arm64 API=25
: > "$TMP/ui.log"
( . "$MODPATH/customize.sh" ) && fail "API 25 must abort" || pass
assert_contains "API abort message" "API 26" "$(cat "$TMP/ui.log")"

stage
ARCH=riscv64 API=34
( . "$MODPATH/customize.sh" ) && fail "unknown arch must abort" || pass

# --- resolver choice with the volume keys -----------------------------------------
resolver_now() { sed -n 's/^RESOLVER=//p' "$UNBOUND_DATA/settings.conf" 2>/dev/null; }

# Fresh install, Vol+ twice then Vol-: Recursive -> Cloudflare -> Quad9, chosen.
rm -rf "$UNBOUND_DATA"
stage; ARCH=arm64 API=34; : > "$TMP/ui.log"
printf 'up\nrelease\nup\ndown\n' > "$STUB_STATE/events"
( . "$MODPATH/customize.sh" ) && pass || fail "customize with key presses"
assert_eq "vol keys chose quad9" "quad9" "$(resolver_now)"
assert_contains "choice confirmed" "Resolver: Quad9" "$(cat "$TMP/ui.log")"

# Update, no key pressed: the current choice is kept, not reset to recursive.
stage; : > "$TMP/ui.log"; : > "$STUB_STATE/events"
UNBOUND_MODDIR="$MODPATH" sh "$MODPATH/ctl.sh" settings-apply RESOLVER=controld >/dev/null
( . "$MODPATH/customize.sh" ) && pass || fail "customize timing out"
assert_eq "update keeps controld" "controld" "$(resolver_now)"
assert_contains "timeout message" "Keeping ControlD" "$(cat "$TMP/ui.log")"

# Fresh install, no key pressed: recursive.
rm -rf "$UNBOUND_DATA"
stage; : > "$TMP/ui.log"; : > "$STUB_STATE/events"
( . "$MODPATH/customize.sh" ) && pass || fail "customize fresh timeout"
assert_eq "fresh install defaults to recursive" "" "$(resolver_now)"
assert_contains "recursive kept" "Keeping Recursive" "$(cat "$TMP/ui.log")"

# Vol+ moved to an option but nothing chosen: still the default.
stage; : > "$TMP/ui.log"; printf 'up\n' > "$STUB_STATE/events"
( . "$MODPATH/customize.sh" ) && pass || fail "customize browse then timeout"
assert_eq "browsing alone does not choose" "" "$(resolver_now)"

# No getevent (e.g. a manager without input access): no question asked.
stage; : > "$TMP/ui.log"
( PATH=/usr/bin:/bin; . "$MODPATH/customize.sh" ) && pass || fail "customize without getevent"
assert_not_contains "no prompt without getevent" "Vol+" "$(cat "$TMP/ui.log")"

# A zip missing one binary for the device's ABI is refused.
stage
rm "$MODPATH/bin/arm64-v8a/curl"
ARCH=arm64 API=34
: > "$TMP/ui.log"
( . "$MODPATH/customize.sh" ) && fail "missing binary must abort" || pass
assert_contains "missing binary named" "no curl binary for arm64-v8a" "$(cat "$TMP/ui.log")"

# uninstall.sh removes the data directory.
stage
echo "PRIVATE_DNS_SAVED=off" > "$UNBOUND_DATA/settings.conf"
sed -i "s|^DATA=.*|DATA=$UNBOUND_DATA|" "$MODPATH/uninstall.sh"
UNBOUND_MODDIR="$MODPATH" sh "$MODPATH/uninstall.sh"
[ -d "$UNBOUND_DATA" ] && fail "uninstall removes data dir" || pass

done_testing
