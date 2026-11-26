#!/bin/sh
# ctl.sh against fake iptables / settings / unbound / curl (tests/stubs).
. "${TESTS_DIR:-$(dirname "$0")}/lib.sh"

MOD="$TMP/module"
cp -R "$REPO_DIR/module" "$MOD"
mkdir -p "$MOD/bin"
cp "$TESTS_DIR"/stubs/bin/* "$MOD/bin/"
printf 'abi=x86_64\nunbound=1.26.2 openssl=3.5.9\n' > "$MOD/bin/BUILDINFO"
printf 'id=unbound-dns\nversion=v1.26.2-r1\n' > "$MOD/module.prop"

export STUB_STATE="$TMP/state"
export UNBOUND_MODDIR="$MOD" UNBOUND_DATA="$TMP/data" UNBOUND_APPDATA="$TMP/appdata"
export UNBOUND_NO_BUSYBOX_REEXEC=1 UNBOUND_POLL=1 UNBOUND_START_TIMEOUT=5
export UNBOUND_IF_INET6="$TMP/if_inet6" UNBOUND_CA_BUNDLE="$TMP/ca.pem"
export PATH="$TESTS_DIR/stubs:$PATH"
mkdir -p "$STUB_STATE/www" "$STUB_STATE/settings" "$TMP/appdata/com.android.captiveportallogin"
echo hostname > "$STUB_STATE/settings/private_dns_mode"
echo dns.example.net > "$STUB_STATE/settings/private_dns_specifier"
echo "fake" > "$TMP/ca.pem"
printf '00000000000000000000000000000001 01 80 10 80       lo\n' > "$TMP/if_inet6"

ctl() { sh "$MOD/ctl.sh" "$@"; }
D="$UNBOUND_DATA"
nat() { cat "$STUB_STATE/$1/nat/$2" 2>/dev/null; }

# wait_for SECONDS CMD...: poll until CMD succeeds.
wait_for() {
    _s="$1"; shift; _i=0
    while [ "$_i" -lt "$((_s * 5))" ]; do "$@" && return 0; sleep 0.2; _i=$((_i + 1)); done
    return 1
}
jump_present() { grep -qx -- '-j UNBOUND_DNS' "$STUB_STATE/iptables/nat/OUTPUT" 2>/dev/null; }
jump_absent() { ! jump_present; }

# --- setup ---------------------------------------------------------------------
assert_ok "setup" ctl setup
for f in unbound.conf control.conf custom.conf runtime.conf blocklist.conf var/root.key lists/sources.list lists/allow.list; do
    [ -f "$D/$f" ] && pass || fail "setup created $f"
done
assert_contains "runtime has ::1" "interface: ::1@5335" "$(cat "$D/runtime.conf")"
: > "$TMP/if_inet6"
ctl setup
assert_not_contains "no ::1 without loopback v6" "::1" "$(cat "$D/runtime.conf")"
printf '00000000000000000000000000000001 01 80 10 80       lo\n' > "$TMP/if_inet6"
echo "# my settings" >> "$D/custom.conf"
ctl setup
assert_contains "custom.conf preserved" "# my settings" "$(cat "$D/custom.conf")"

# --- input validation ----------------------------------------------------------
before="$(cat "$D/lists/sources.list")"
for bad in "https://x.com/a'; rm -rf /" 'https://x.com/$(id)' 'https://x.com/`id`' \
           "http://plain.example.com/list.txt" "https://x.com/a b" "ftp://x.com/l" \
           "https://x.com/a
https://evil.com/" "" "javascript:alert(1)"; do
    assert_fails "reject url: $bad" ctl list-add "$bad"
done
assert_fails "reject name with quote" ctl list-add "https://x.com/l.txt" "bad'name"
assert_fails "reject name with \$()" ctl list-add "https://x.com/l.txt" 'a$(id)'
assert_eq "sources untouched" "$before" "$(cat "$D/lists/sources.list")"
for bad in "a.com;reboot" "a.com'" '$(id).com' "nodot" "a..com" "-a.com" "a.com
b.com"; do
    assert_fails "reject domain: $bad" ctl allow-add "$bad"
done
assert_eq "allowlist untouched" "" "$(cat "$D/lists/allow.list")"
assert_fails "reject bad id" ctl list-remove "../../etc"
assert_fails "reject refresh 0" ctl set refresh_hours 0
assert_fails "reject refresh 1000" ctl set refresh_hours 1000
assert_fails "reject refresh text" ctl set refresh_hours "1;id"
assert_ok "accept refresh 12" ctl set refresh_hours 12

# --- lists ---------------------------------------------------------------------
printf '0.0.0.0 ads.example.com\n0.0.0.0 track.example.com\n0.0.0.0 cdn.ok.example.org\n' > "$STUB_STATE/www/hosts.txt"
printf '||example.org^\n@@||safe.example.org^\n' > "$STUB_STATE/www/abp.txt"
id1="$(ctl list-add "https://lists.example/hosts.txt" "Test hosts")"
id2="$(ctl list-add "https://lists.example/abp.txt")"
assert_eq "id format" "1" "$(printf '%s' "$id1" | grep -Ec '^[0-9a-f]{12}$')"
assert_fails "duplicate list rejected" ctl list-add "https://lists.example/hosts.txt"
assert_contains "default name from host" "lists.example" "$(cat "$D/lists/sources.list")"

assert_ok "update-lists" ctl update-lists
conf="$(cat "$D/blocklist.conf")"
assert_contains "blocks hosts entry" 'local-zone: "ads.example.com." always_nxdomain' "$conf"
assert_contains "blocks abp entry" 'local-zone: "example.org." always_nxdomain' "$conf"
assert_contains "list exception allowed" 'local-zone: "safe.example.org." transparent' "$conf"
assert_not_contains "covered subdomain pruned" "cdn.ok.example.org" "$conf"
assert_eq "blocked count" "3" "$(cat "$D/blocklist.count")"

json="$(ctl lists)"
assert_json "lists json" "$json"
assert_contains "lists json has name" '"name":"Test hosts"' "$json"
assert_contains "lists json has count" '"count":3' "$json"

# A failing download keeps the last good copy and records the error.
touch "$STUB_STATE/curl.fail"
assert_fails "update with failing download" ctl update-lists --force
assert_eq "blocklist kept after failure" "$conf" "$(cat "$D/blocklist.conf")"
json="$(ctl lists)"
assert_contains "error recorded" '"status":"error"' "$json"
assert_contains "error message" "404" "$json"
assert_json "lists json with error" "$json"
rm -f "$STUB_STATE/curl.fail"

assert_ok "allow-add" ctl allow-add Track.Example.com
assert_not_contains "allowlisted name unblocked" '"track.example.com."' "$(cat "$D/blocklist.conf")"
assert_eq "allowlist stored normalised" "track.example.com" "$(cat "$D/lists/allow.list")"
assert_ok "allow-remove" ctl allow-remove track.example.com
assert_contains "block back after allow-remove" '"track.example.com."' "$(cat "$D/blocklist.conf")"

assert_ok "disable list" ctl list-enable "$id2" 0
assert_not_contains "disabled list not applied" '"example.org."' "$(cat "$D/blocklist.conf")"
assert_ok "enable list" ctl list-enable "$id2" 1
assert_ok "remove list" ctl list-remove "$id1"
assert_not_contains "removed list gone" "ads.example.com" "$(cat "$D/blocklist.conf")"

mkdir -p "$D/lists/local"
printf 'local-block.example\n' > "$D/lists/local/mine.txt"
ctl rebuild
assert_contains "local file applied" '"local-block.example."' "$(cat "$D/blocklist.conf")"
assert_contains "local file in json" '"file":"mine.txt","count":1' "$(ctl lists)"

# --- daemon: start, redirect, private DNS ----------------------------------------
sh "$MOD/ctl.sh" daemon >/dev/null 2>&1 &
wait_for 10 jump_present && pass || fail "redirect applied after start"
rules="$(nat iptables UNBOUND_DNS)"
assert_eq "first rule exempts unbound uid" "-m owner --uid-owner 3003 -j RETURN" "$(echo "$rules" | head -n 1)"
assert_contains "network stack exempt" "--uid-owner 1073 -j RETURN" "$rules"
assert_contains "captive portal app exempt" "--uid-owner $(stat -c %u "$TMP/appdata/com.android.captiveportallogin") -j RETURN" "$rules"
assert_contains "udp redirect" "-p udp --dport 53 -j REDIRECT --to-ports 5335" "$rules"
assert_contains "tcp redirect" "-p tcp --dport 53 -j REDIRECT --to-ports 5335" "$rules"
assert_contains "ipv6 redirect" "-p udp --dport 53 -j REDIRECT --to-ports 5335" "$(nat ip6tables UNBOUND_DNS)"
assert_contains "dot rejected" "-p tcp --dport 853 -j REJECT --reject-with tcp-reset" "$(cat "$STUB_STATE/iptables/filter/UNBOUND_DOT")"
# NAT64 discovery (ipv4only.arpa) goes to the network's DNS64, ahead of the redirect.
nat64_rule='-p udp --dport 53 -m string --algo bm --icase --hex-string |08|ipv4only|04|arpa|00| -j RETURN'
for fam in iptables ip6tables; do
    r="$(nat $fam UNBOUND_DNS)"
    assert_contains "$fam: NAT64 discovery bypass" "$nat64_rule" "$r"
    first_redirect="$(echo "$r" | grep -n REDIRECT | head -n 1 | cut -d: -f1)"
    bypass_line="$(echo "$r" | grep -n ipv4only | cut -d: -f1)"
    [ -n "$bypass_line" ] && [ "$bypass_line" -lt "$first_redirect" ] && pass || fail "$fam: bypass must come before REDIRECT"
done
pd_off() { [ "$(cat "$STUB_STATE/settings/private_dns_mode")" = off ]; }
wait_for 5 pd_off && pass || fail "private dns turned off"
assert_eq "private dns saved" "hostname" "$(sed -n 's/^PRIVATE_DNS_SAVED=//p' "$D/settings.conf")"

json="$(ctl status)"
assert_json "status json" "$json"
assert_contains "status running" '"running":true' "$json"
assert_contains "status redirect" '"redirect_active":true' "$json"
assert_contains "status queries" '"queries":42' "$json"
assert_contains "status version" '"version":"1.26.2"' "$json"
assert_contains "status nat64 bypass" '"nat64_bypass_v6":"ok"' "$json"

# Unbound dies -> redirect removed, Unbound restarted, redirect back.
kill "$(cat "$STUB_STATE/unbound.pid")"
wait_for 10 grep -q "redirect: removed because Unbound is not running" "$D/var/module.log" \
    && pass || fail "redirect removed when unbound died"
wait_for 15 jump_present && pass || fail "redirect back after restart"

# User turns the redirect off and on.
assert_eq "redirect off" "redirect: off" "$(ctl redirect off)"
jump_absent && pass || fail "rules gone after redirect off"
assert_eq "redirect on" "redirect: on" "$(ctl redirect on)"

assert_eq "stop" "stopped" "$(ctl stop)"
jump_absent && pass || fail "rules gone after stop"
[ -f "$STUB_STATE/unbound.pid" ] && fail "unbound still running after stop" || pass

# --- daemon: broken config never redirects ---------------------------------------
echo BROKEN >> "$D/custom.conf"
: > "$STUB_STATE/calls.log"
sh "$MOD/ctl.sh" daemon >/dev/null 2>&1 &
wait_for 10 grep -q "unbound: failed to start" "$D/var/module.log" && pass || fail "start failure logged"
sleep 2
jump_absent && pass || fail "no redirect while unbound cannot start"
assert_contains "status shows error" "syntax error" "$(ctl status)"
# Fixing the config and asking for a restart retries at once, not after
# the back-off.
sleep 6
sed -i '/BROKEN/d' "$D/custom.conf"
ctl restart >/dev/null
wait_for 4 jump_present && pass || fail "restart retries immediately after a fix"
ctl stop >/dev/null

# --- daemon: kernel without IPv6 NAT ---------------------------------------------
touch "$STUB_STATE/ip6tables.nonat"
sh "$MOD/ctl.sh" daemon >/dev/null 2>&1 &
wait_for 10 jump_present && pass || fail "ipv4 redirect without ipv6 nat"
assert_contains "status ipv6 unsupported" '"ipv6":"unsupported"' "$(ctl status)"
ctl stop >/dev/null
rm -f "$STUB_STATE/ip6tables.nonat"

# --- daemon: kernel without the string match -------------------------------------
touch "$STUB_STATE/iptables.nostring" "$STUB_STATE/ip6tables.nostring"
sh "$MOD/ctl.sh" daemon >/dev/null 2>&1 &
wait_for 10 jump_present && pass || fail "redirect works without string match"
assert_not_contains "no bypass rule without string match" "ipv4only" "$(nat iptables UNBOUND_DNS)"
assert_contains "status reports missing bypass" '"nat64_bypass_v6":"unsupported"' "$(ctl status)"
ctl stop >/dev/null
rm -f "$STUB_STATE/iptables.nostring" "$STUB_STATE/ip6tables.nostring"

# --- module disabled in the manager -> daemon stops and restores ------------------
sh "$MOD/ctl.sh" daemon >/dev/null 2>&1 &
wait_for 10 jump_present
touch "$MOD/disable"
daemon_gone() { ! [ -f "$D/run/daemon.pid" ]; }
wait_for 10 daemon_gone && pass || fail "daemon stops when module disabled"
jump_absent && pass || fail "rules removed when module disabled"
assert_eq "private dns restored" "hostname" "$(cat "$STUB_STATE/settings/private_dns_mode")"
assert_eq "private dns spec restored" "dns.example.net" "$(cat "$STUB_STATE/settings/private_dns_specifier")"
rm -f "$MOD/disable"

done_testing
