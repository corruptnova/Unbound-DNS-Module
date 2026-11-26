#!/bin/sh
# customize.sh / uninstall.sh as the root manager runs them.
. "${TESTS_DIR:-$(dirname "$0")}/lib.sh"

export UNBOUND_DATA="$TMP/data" UNBOUND_NO_BUSYBOX_REEXEC=1
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
        for b in unbound unbound-control curl; do
            printf '#!/bin/sh\necho %s-%s\n' "$abi" "$b" > "$MODPATH/bin/$abi/$b"
            chmod 0755 "$MODPATH/bin/$abi/$b"
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

# uninstall.sh removes the data directory.
stage
echo "PRIVATE_DNS_SAVED=off" > "$UNBOUND_DATA/settings.conf"
sed -i "s|^DATA=.*|DATA=$UNBOUND_DATA|" "$MODPATH/uninstall.sh"
UNBOUND_MODDIR="$MODPATH" sh "$MODPATH/uninstall.sh"
[ -d "$UNBOUND_DATA" ] && fail "uninstall removes data dir" || pass

done_testing
