#!/bin/sh
# The shipped unbound.conf + a generated blocklist, served by a real Unbound
# on the build host. Skipped when unbound/dig are not installed.
. "${TESTS_DIR:-$(dirname "$0")}/lib.sh"
. "$LIB_DIR/lists.sh"

UNBOUND="${UNBOUND_BIN:-$(command -v unbound || ls /usr/sbin/unbound 2>/dev/null)}"
UCTL="${UNBOUND_CONTROL_BIN:-$(command -v unbound-control || ls /usr/sbin/unbound-control 2>/dev/null)}"
CHECK="$(command -v unbound-checkconf || ls /usr/sbin/unbound-checkconf 2>/dev/null)"
if [ -z "$UNBOUND" ] || [ -z "$UCTL" ] || ! command -v dig >/dev/null 2>&1; then
    echo "test_unbound_live.sh: skipped (needs unbound, unbound-control, dig)"
    exit 0
fi
[ "$(id -u)" = 0 ] || { echo "test_unbound_live.sh: skipped (needs root for privileged paths)"; exit 0; }

T="$TMP/data"
PORT=53535
mkdir -p "$T/var"
# Same files the module installs, with the chroot/user switched off and
# paths moved to a temp dir.
for f in unbound.conf control.conf custom.conf; do
    sed -e "s|/data/adb/unbound|$T|g" -e 's|^\( *username:\).*|\1 ""|' \
        -e 's|^\( *chroot:\).*|\1 ""|' -e "s|5335|$PORT|g" \
        "$REPO_DIR/module/conf/$f" > "$T/$f"
done
cp "$REPO_DIR/module/conf/root.key" "$T/var/root.key"
printf 'server:\n    interface: 127.0.0.1@%s\n' "$PORT" > "$T/runtime.conf"
cat >> "$T/custom.conf" <<'EOF'
server:
    local-data: "ok.ads.example.com. A 192.0.2.1"
    local-data: "ads.example.com. A 192.0.2.2"
EOF
printf 'B ads.example.com\nA ok.ads.example.com\nB other.test\n' | lists_merge "$T/blocklist.conf" "$T/count"

if [ -n "$CHECK" ]; then
    assert_ok "unbound-checkconf" "$CHECK" "$T/unbound.conf"
fi

"$UNBOUND" -d -c "$T/unbound.conf" > "$TMP/unbound.out" 2>&1 &
UB=$!
trap 'kill $UB 2>/dev/null; rm -rf "$TMP"' EXIT
i=0
until "$UCTL" -c "$T/control.conf" status >/dev/null 2>&1; do
    i=$((i + 1))
    if [ $i -gt 50 ]; then cat "$TMP/unbound.out" "$T/var/unbound.log" 2>/dev/null; fail "unbound did not start"; done_testing; exit 1; fi
    sleep 0.2
done
pass

q() { dig +time=3 +tries=1 @127.0.0.1 -p "$PORT" "$@"; }
assert_contains "blocked name is NXDOMAIN" "status: NXDOMAIN" "$(q ads.example.com A)"
assert_contains "blocked subdomain is NXDOMAIN" "status: NXDOMAIN" "$(q x.y.ads.example.com A)"
assert_contains "other blocked zone" "status: NXDOMAIN" "$(q other.test AAAA)"
assert_eq "allowlisted name under blocked parent resolves" "192.0.2.1" "$(q +short ok.ads.example.com A)"
assert_ok "reload_keep_cache over unix socket" "$UCTL" -c "$T/control.conf" reload_keep_cache
assert_contains "still blocking after reload" "status: NXDOMAIN" "$(q ads.example.com A)"
assert_contains "identity hidden" "status: REFUSED" "$(q id.server CH TXT)"
assert_ok "log written" test -s "$T/var/unbound.log"

done_testing
