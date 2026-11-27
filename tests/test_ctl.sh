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
export UNBOUND_NO_BUSYBOX_REEXEC=1 UNBOUND_POLL=1 UNBOUND_START_TIMEOUT=5 UNBOUND_APPLY_TIMEOUT=10
export UNBOUND_IF_INET6="$TMP/if_inet6" UNBOUND_CA_BUNDLE="$TMP/ca.pem"
export PATH="$TESTS_DIR/stubs:$PATH"
# A stand-in for /sys/fs/selinux: "context" exists only while a test says
# the module's policy is loaded.
SEFS="$TMP/selinuxfs"
export UNBOUND_SELINUXFS="$SEFS"
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
assert_contains "curl runs unprivileged (nobody, inet group)" \
    "dropexec run 9999 9999 3003 $MOD/bin/curl -q " "$(grep "^dropexec run" "$STUB_STATE/calls.log")"
assert_contains "curl gets the CA bundle on fd 3" "--cacert /proc/self/fd/3" "$(grep "^dropexec run" "$STUB_STATE/calls.log")"
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

# Own blocklist: domain + subdomains, "*." accepted, patterns rejected.
assert_ok "block-add wildcard form" ctl block-add "*.Own-Block.Example.net"
assert_eq "own block stored normalised" "own-block.example.net" "$(cat "$D/lists/block.list")"
assert_contains "own block applied" 'local-zone: "own-block.example.net." always_nxdomain' "$(cat "$D/blocklist.conf")"
assert_contains "own block in lists json" '"block":["own-block.example.net"]' "$(ctl lists)"
for bad in "ads*.example.com" "*tracker*" "a.com;reboot" '$(id).com' "nodot" "*." "a.com
b.com"; do
    assert_fails "reject own block: $bad" ctl block-add "$bad"
done
assert_eq "own blocklist untouched by bad input" "own-block.example.net" "$(cat "$D/lists/block.list")"
# Allowlist on the same name wins; own block under an allowed parent wins.
ctl allow-add own-block.example.net >/dev/null
assert_not_contains "exact tie goes to the allowlist" '"own-block.example.net." always' "$(cat "$D/blocklist.conf")"
ctl allow-remove own-block.example.net >/dev/null
ctl allow-add example.org >/dev/null
ctl block-add ads.example.org >/dev/null
assert_contains "own block beats allowed parent" '"ads.example.org." always_nxdomain' "$(cat "$D/blocklist.conf")"
ctl allow-remove example.org >/dev/null
assert_ok "block-remove" ctl block-remove own-block.example.net
assert_eq "own block removed" "ads.example.org" "$(cat "$D/lists/block.list")"
ctl block-remove ads.example.org >/dev/null

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
# Only as the question name: right after the DNS header.
for fam in iptables ip6tables; do
    if [ "$fam" = iptables ]; then at=40; else at=60; fi
    nat64_rule="-p udp --dport 53 -m string --algo bm --icase --from $at --to $((at + 15)) --hex-string |08|ipv4only|04|arpa|00| -m string --algo bm --icase --from $((at + 1)) --to 65535 ! --hex-string |08|ipv4only|04|arpa|00| -j RETURN"
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
# Statistics keep counting across reloads (list updates) and restarts.
stub_counts() { echo "$1" > "$STUB_STATE/ub.queries"; echo "$2" > "$STUB_STATE/ub.hits"; }
stub_counts 42 40
assert_contains "status queries" '"queries":42' "$(ctl status)"
ctl rebuild >/dev/null                      # reloads Unbound, which zeroes its counters
stub_counts 5 1
json="$(ctl status)"
assert_contains "queries survive a reload" '"queries":47' "$json"
assert_contains "cache hits survive a reload" '"cache_hits":41' "$json"
old_pid="$(cat "$STUB_STATE/unbound.pid")"
ctl restart >/dev/null
restarted() {
    [ -f "$STUB_STATE/unbound.pid" ] && [ "$(cat "$STUB_STATE/unbound.pid")" != "$old_pid" ] \
        && ctl status | grep -q '"running":true' && jump_present
}
wait_for 10 restarted && pass || fail "unbound restarted"
stub_counts 3 0
assert_contains "queries survive a restart" '"queries":50' "$(ctl status)"
assert_contains "counting since is reported" '"stats_since":' "$(ctl status)"
ctl stats-reset >/dev/null
assert_contains "stats reset" '"queries":0' "$(ctl status)"
assert_contains "cache hits reset" '"cache_hits":0' "$(ctl status)"
assert_contains "status version" '"version":"1.26.2"' "$json"
assert_contains "status nat64 bypass" '"nat64_bypass_v6":"ok"' "$json"

# Unbound dies -> redirect removed, Unbound restarted, redirect back.
log_mark="$(wc -l < "$D/log/module.log")"
new_log_has() { tail -n +"$((log_mark + 1))" "$D/log/module.log" | grep -q "$1"; }
kill "$(cat "$STUB_STATE/unbound.pid")"
wait_for 10 new_log_has "redirect: removed because Unbound is not running" \
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
wait_for 10 grep -q "unbound: failed to start" "$D/log/module.log" && pass || fail "start failure logged"
sleep 2
jump_absent && pass || fail "no redirect while unbound cannot start"
assert_contains "status shows error" "syntax error" "$(ctl status)"
# The error must stay visible through the supervisor's retries, not vanish
# while a new attempt is starting up.
missing=0
for i in $(seq 1 25); do
    ctl status | grep -q '"error":"[^"]*syntax error' || missing=$((missing + 1))
    sleep 0.4
done
assert_eq "start error stays visible during retries" "0" "$missing"
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

# --- settings: validation (nothing written on bad input) ----------------------------
json="$(ctl settings)"
assert_json "settings json" "$json"
assert_contains "default resolver" '"RESOLVER":"recursive"' "$json"
assert_contains "anchor keys listed" '"id":20326' "$json"
before_settings="$(cat "$D/settings.conf")"
for bad in "RESOLVER=mullvad" "CACHE_SIZE=huge" "THREADS=9" "THREADS=1;id" "CACHE_MIN_TTL=-1" \
           "LOG_LEVEL=" "NOPE=1" "DNSSEC=yes" "RESOLVER=custom" "FORWARDERS=1.2.3.4" \
           "FORWARDERS=1.2.3.4#a b" 'FORWARDERS=$(id)#x.com' "FORWARDERS=1.2.3.4#x.com;reboot" \
           "PREFETCH"; do
    assert_fails "reject setting: $bad" ctl settings-apply "$bad"
done
assert_fails "min ttl above max rejected" ctl settings-apply CACHE_MIN_TTL=600 CACHE_MAX_TTL=300
assert_fails "one bad value rejects all" ctl settings-apply CACHE_SIZE=large THREADS=99
assert_eq "settings untouched by bad input" "$before_settings" "$(cat "$D/settings.conf")"
[ -f "$D/forwarders.list" ] && fail "no forwarders written on bad input" || pass

# --- settings: rendering without a running Unbound (installer path) ------------------
assert_contains "apply without daemon only saves" '"applied":false' "$(ctl settings-apply RESOLVER=quad9)"
opts="$(cat "$D/options.conf")"
assert_contains "quad9 forward zone" 'forward-tls-upstream: yes' "$opts"
assert_contains "quad9 server" 'forward-addr: 9.9.9.9@853#dns.quad9.net' "$opts"
assert_contains "quad9 ipv6 server" 'forward-addr: 2620:fe::fe@853#dns.quad9.net' "$opts"
assert_contains "ca bundle in chroot" "tls-cert-bundle: \"$D/ca.pem\"" "$opts"
[ -s "$D/ca.pem" ] && pass || fail "ca.pem installed"
assert_contains "status shows resolver" '"resolver":"quad9"' "$(ctl status)"
ctl settings-apply RESOLVER=controld >/dev/null
assert_contains "controld server" 'forward-addr: 76.76.2.0@853#p0.freedns.controld.com' "$(cat "$D/options.conf")"
ctl settings-apply RESOLVER=cloudflare >/dev/null
assert_contains "cloudflare server" 'forward-addr: 1.1.1.1@853#cloudflare-dns.com' "$(cat "$D/options.conf")"
ctl settings-apply "RESOLVER=custom" "FORWARDERS=192.0.2.1#dns.example,2001:db8::1@8853#dns.example" >/dev/null
assert_eq "custom servers stored" "192.0.2.1#dns.example
2001:db8::1@8853#dns.example" "$(cat "$D/forwarders.list")"
assert_contains "custom server rendered" 'forward-addr: 2001:db8::1@8853#dns.example' "$(cat "$D/options.conf")"
ctl settings-apply RESOLVER=recursive >/dev/null
assert_not_contains "recursive has no forward zone" 'forward-zone' "$(cat "$D/options.conf")"

ctl settings-apply CACHE_SIZE=large THREADS=3 DNSSEC=0 REBIND_PROTECT=1 QNAME_MIN=0 LOG_LEVEL=2 \
    CACHE_MIN_TTL=60 CACHE_MAX_TTL=3600 PREFETCH=0 SERVE_EXPIRED=0 UPSTREAM_IPV6=0 >/dev/null
opts="$(cat "$D/options.conf")"
for want in "msg-cache-size: 32m" "rrset-cache-size: 64m" "num-threads: 3" "msg-cache-slabs: 4" \
            'module-config: "iterator"' "private-address: 192.168.0.0/16" "qname-minimisation: no" \
            "verbosity: 2" "cache-min-ttl: 60" "cache-max-ttl: 3600" "prefetch: no" "serve-expired: no"; do
    assert_contains "renders $want" "$want" "$opts"
done
assert_contains "ipv6 upstream off" "do-ip6: no" "$(cat "$D/runtime.conf")"
ctl settings-apply DNSSEC=1 DNSSEC_PERMISSIVE=1 >/dev/null
assert_contains "permissive dnssec" "val-permissive-mode: yes" "$(cat "$D/options.conf")"
ctl block-add null-answer.example >/dev/null
ctl settings-apply BLOCK_ANSWER=null >/dev/null
assert_contains "block answer 0.0.0.0" '"null-answer.example." always_null' "$(cat "$D/blocklist.conf")"
ctl block-remove null-answer.example >/dev/null
ctl settings-reset >/dev/null
assert_eq "reset restores defaults" "$(ctl settings | grep -o '"settings":{[^}]*}' | sed 's/"settings"//')" \
    "$(ctl settings | grep -o '"defaults":{[^}]*}' | sed 's/"defaults"//')"
[ -f "$D/forwarders.list" ] && fail "reset removes custom servers" || pass
assert_contains "reset rebuilds nxdomain blocks" "always_nxdomain" "$(cat "$D/blocklist.conf")"

# --- settings: applied to a running Unbound, rolled back when it fails ------------
STUB_UNBOUND_FAIL_IF='cache-max-ttl: 999' sh "$MOD/ctl.sh" daemon >/dev/null 2>&1 &
wait_for 10 jump_present
assert_contains "apply restarts unbound" '"applied":true' "$(ctl settings-apply CACHE_SIZE=small)"
out="$(ctl settings-apply CACHE_MAX_TTL=999)"
assert_contains "bad apply reported" '"ok":false' "$out"
assert_contains "bad apply shows unbound's error" "value out of range" "$out"
assert_not_contains "setting rolled back" "CACHE_MAX_TTL=999" "$(cat "$D/settings.conf")"
assert_contains "earlier setting kept" "CACHE_SIZE=small" "$(cat "$D/settings.conf")"
wait_for 10 jump_present && pass || fail "unbound and redirect back after rollback"

printf 'server:\n    # my addition\n' > "$TMP/custom.txt"
assert_contains "custom-set applies" '"applied":true' "$(ctl custom-set "$(base64 < "$TMP/custom.txt" | tr -d '\n')")"
assert_eq "custom-get returns it" "$(cat "$TMP/custom.txt")" "$(ctl custom-get)"
printf 'server:\n    BROKEN: yes\n' > "$TMP/broken.txt"
out="$(ctl custom-set "$(base64 < "$TMP/broken.txt" | tr -d '\n')")"
assert_contains "broken custom.conf rejected" '"ok":false' "$out"
assert_eq "custom.conf restored" "$(cat "$TMP/custom.txt")" "$(cat "$D/custom.conf")"
assert_fails "custom-set rejects bad encoding" ctl custom-set 'not base64!'

# --- trust anchor -----------------------------------------------------------------------
assert_contains "anchor up to date" '"changed":false' "$(ctl anchor-update)"
touch "$STUB_STATE/anchor.fail"
assert_contains "anchor failure reported" "no address" "$(ctl anchor-update)"
rm -f "$STUB_STATE/anchor.fail"
touch "$STUB_STATE/anchor.update"
assert_contains "anchor updated" '"applied":true' "$(ctl anchor-update)"
assert_contains "new anchor installed" "99999" "$(cat "$D/var/root.key")"
rm -f "$STUB_STATE/anchor.update"
assert_contains "anchor reset" '"applied":true' "$(ctl anchor-reset)"
assert_eq "built-in anchor restored" "$(cat "$MOD/conf/root.key")" "$(cat "$D/var/root.key")"
# Once running, Unbound rewrites root.key in its own format: tab-separated
# fields and state comments. The status must read that too.
TAB="$(printf '\t')"
{
    echo "; autotrust trust anchor file"
    echo ";;id: . 1"
    echo ";;last_queried: 1795690000 ;;Wed Nov 26 10:00:00 2026"
    echo ";;last_success: 1795690000 ;;Wed Nov 26 10:00:00 2026"
    echo ";;query_failed: 0"
    echo ".${TAB}172800${TAB}IN${TAB}DNSKEY${TAB}257 3 8 AwEAAaz/tAm8 ;{id = 20326 (ksk), size = 2048b} ;;state=2 [  VALID  ] ;;count=0 ;;lastchange=1795600000 ;;Tue Nov 25 10:00:00 2026"
    echo ".${TAB}172800${TAB}IN${TAB}DNSKEY${TAB}257 3 8 AwEAAa96jeuk ;{id = 38696 (ksk), size = 2048b} ;;state=1 [ ADDPEND ] ;;count=2 ;;lastchange=1795600000 ;;Tue Nov 25 10:00:00 2026"
} > "$D/var/root.key"
json="$(ctl settings)"
assert_json "settings json with autotrust file" "$json"
assert_contains "autotrust key 20326 read" '{"id":20326,"state":"VALID"}' "$json"
assert_contains "autotrust key 38696 read" '{"id":38696,"state":"ADDPEND"}' "$json"
assert_contains "autotrust last success read" '"last_success":1795690000' "$json"
cp "$MOD/conf/root.key" "$D/var/root.key"
ctl stop >/dev/null
ctl settings-reset >/dev/null

# --- root never follows what the Unbound user leaves in var/ ----------------------
# A compromised Unbound owns var/ and could plant links there. Nothing root
# does may write, chown or read through them.
victim="$TMP/victim"; mkdir -p "$victim/dir"
echo precious > "$victim/file"; chmod 0600 "$victim/file"
victim_intact() {
    [ "$(cat "$victim/file")" = precious ] && [ "$(stat -c '%u:%g %a' "$victim/file")" = "0:0 600" ] \
        && [ -z "$(ls -A "$victim/dir")" ]
}
plant() {
    rm -rf "$D/var/root.key"
    ln -s "$victim/file" "$D/var/root.key"
    for n in module.log unbound.log unbound.stderr; do rm -f "$D/var/$n"; ln -s "$victim/file" "$D/var/$n"; done
    rm -f "$D/var/unbound.log.1" "$D/var/module.log.1"
    ln -s "$victim/dir" "$D/var/unbound.log.1"; ln -s "$victim/dir" "$D/var/module.log.1"
}
plain_root_key() { [ -f "$D/var/root.key" ] && [ ! -L "$D/var/root.key" ]; }
plant
ctl setup
victim_intact && pass || fail "setup left the planted links alone"
plain_root_key && pass || fail "setup replaced the planted root.key"
assert_eq "built-in anchor after a planted link" "$(cat "$MOD/conf/root.key")" "$(cat "$D/var/root.key")"
[ ! -e "$D/var/module.log" ] && [ ! -L "$D/var/unbound.stderr" ] && pass || fail "old log names removed from var/"
assert_eq "root.key owned by the Unbound user" "3003:3003" "$(stat -c '%u:%g' "$D/var/root.key")"
plant
assert_contains "anchor reset with a planted link" '"ok":true' "$(ctl anchor-reset)"
victim_intact && pass || fail "anchor reset did not follow the link"
plain_root_key && pass || fail "anchor reset replaced the link"
plant
ctl anchor-update >/dev/null
victim_intact && pass || fail "anchor update did not read or write through the link"
plant
ctl settings-apply CACHE_SIZE=small >/dev/null
victim_intact && pass || fail "settings apply (backup) did not follow the link"
echo BROKEN >> "$D/custom.conf"
plant
ctl settings-apply CACHE_SIZE=large >/dev/null
sed -i '/^BROKEN$/d' "$D/custom.conf"
victim_intact && pass || fail "rollback did not follow the link"
# A folder or a pipe in place of root.key is replaced too, and never blocks.
rm -rf "$D/var/root.key"; mkdir "$D/var/root.key"; ln -s "$victim/file" "$D/var/root.key/x"
ctl setup
plain_root_key && pass || fail "folder in place of root.key replaced"
victim_intact && pass || fail "folder contents not followed"
rm -f "$D/var/root.key"; mkfifo "$D/var/root.key"
json="$(timeout 10 sh "$MOD/ctl.sh" settings)"
assert_contains "settings readable with a pipe as root.key" '"keys":[]' "$json"
ctl setup
plain_root_key && pass || fail "pipe in place of root.key replaced"
ctl stop >/dev/null
ctl settings-reset >/dev/null

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

# --- SELinux: Unbound in its own domain when the module's policy is loaded -------
se_state() { ctl status | sed -n 's/.*"selinux":"\([a-z]*\)".*/\1/p'; }
# Not loaded (another root manager, or before the reboot after installing).
: > "$STUB_STATE/calls.log"
UNBOUND_MAINT=600 sh "$MOD/ctl.sh" daemon >/dev/null 2>&1 &
wait_for 10 jump_present
assert_eq "no policy: unconfined" "unconfined" "$(se_state)"
grep -q '^runcon ' "$STUB_STATE/calls.log" && fail "runcon used without the policy" || pass
ctl stop >/dev/null; wait_for 10 daemon_gone
# Root can label files with types the policy lacks, so chcon working must
# not count as the policy being loaded: only the kernel's context check does.
touch "$STUB_STATE/selinux"
UNBOUND_MAINT=600 sh "$MOD/ctl.sh" daemon >/dev/null 2>&1 &
wait_for 10 jump_present
assert_eq "chcon alone is not the policy" "unconfined" "$(se_state)"
ctl stop >/dev/null; wait_for 10 daemon_gone
# Loaded: label the binary, then start it through runcon in unbound_dns.
mkdir -p "$SEFS"; : > "$SEFS/context"; : > "$STUB_STATE/calls.log"
UNBOUND_MAINT=600 sh "$MOD/ctl.sh" daemon >/dev/null 2>&1 &
wait_for 10 jump_present
assert_eq "policy loaded: learning" "learning" "$(se_state)"
assert_contains "binary labelled" "chcon u:object_r:unbound_dns_exec:s0 $MOD/bin/unbound" "$(cat "$STUB_STATE/calls.log")"
assert_contains "started in its domain" "runcon -- u:r:unbound_dns:s0 $MOD/bin/unbound -d -c" "$(cat "$STUB_STATE/calls.log")"
# The stub parses like BusyBox's runcon, which took Unbound's -d for its own
# option when no "--" came first.
assert_contains "BusyBox-style runcon needs --" "Usage: runcon" "$(runcon u:r:unbound_dns:s0 /bin/true -d 2>&1)"
assert_eq "context checked with the kernel" "u:r:unbound_dns:s0" "$(cat "$SEFS/context")"
ctl stop >/dev/null; wait_for 10 daemon_gone
# The domain does not work: run Unbound the old way and say why.
touch "$STUB_STATE/runcon.fail"
UNBOUND_MAINT=600 sh "$MOD/ctl.sh" daemon >/dev/null 2>&1 &
wait_for 15 jump_present && pass || fail "unbound runs after falling back"
assert_eq "fallback reported" "fallback" "$(se_state)"
assert_contains "fallback logged" "selinux: Unbound could not start in its own domain" "$(cat "$D/log/module.log")"
assert_contains "reason kept" "can't set up security context" "$(ctl selinux-report)"
ctl stop >/dev/null; wait_for 10 daemon_gone
rm -f "$STUB_STATE/runcon.fail"
# Accesses logged for the domain are kept, each kind once, without pids.
cat > "$STUB_STATE/dmesg.txt" <<'EOF'
[   12.3] audit: type=1400 audit(1.2:3): avc:  denied  { read } for  pid=1234 comm="unbound" name="root.key" dev="dm-5" ino=42 scontext=u:r:unbound_dns:s0 tcontext=u:object_r:adb_data_file:s0 tclass=file permissive=1
[   12.4] audit: type=1400 audit(1.2:4): avc:  denied  { read } for  pid=999 comm="unbound" name="root.key" dev="dm-5" ino=43 scontext=u:r:unbound_dns:s0 tcontext=u:object_r:adb_data_file:s0 tclass=file permissive=1
[   12.5] audit: type=1400 audit(1.2:5): avc:  denied  { read } for  pid=5 comm="other" scontext=u:r:untrusted_app:s0 tcontext=u:object_r:system_file:s0 tclass=file permissive=0
[   12.6] audit: audit_lost=3 audit_rate_limit=5 audit_backlog_limit=64
[   13.0] audit: audit_lost=7 audit_rate_limit=5 audit_backlog_limit=64
EOF
printf '%s\n' '11-27 10:00:00.000  1234  1234 W unbound : type=1400 audit(0.0:7): avc:  denied  { name_bind } for  src=5335 scontext=u:r:unbound_dns:s0 tcontext=u:object_r:port:s0 tclass=udp_socket permissive=1' > "$STUB_STATE/logcat.txt"
report="$(ctl selinux-report)"
assert_eq "two kinds kept" "2" "$(printf '%s\n' "$report" | grep -c 'avc: denied')"
assert_not_contains "pids dropped" "pid=" "$report"
assert_contains "dropped audit messages shown" "dropped since boot (all apps): 7" "$report"
assert_contains "socket kind kept" "{ name_bind }" "$report"
assert_not_contains "other domains ignored" "untrusted_app" "$report"
assert_eq "kept across reports" "2" "$(rm -f "$STUB_STATE/dmesg.txt"; ctl selinux-report | grep -c 'avc: denied')"
assert_contains "diagnostics include them" "== SELinux" "$(ctl diag)"
rm -f "$STUB_STATE/selinux" "$STUB_STATE/logcat.txt" "$SEFS/context"

# --- rules removed by something else are put back ---------------------------------
v6_jump_present() { grep -qx -- '-j UNBOUND_DNS' "$STUB_STATE/ip6tables/nat/OUTPUT" 2>/dev/null; }
dot_jump_present() { grep -qx -- '-j UNBOUND_DOT' "$STUB_STATE/iptables/filter/OUTPUT" 2>/dev/null; }
calls_since() { tail -n "+$(( $1 + 1 ))" "$STUB_STATE/calls.log"; }
ncalls() { wc -l < "$STUB_STATE/calls.log"; }
# Another firewall app's own chains and rules, one of them above ours.
iptables -w -t nat -N FW_APP; iptables -w -t nat -A FW_APP -p udp --dport 53 -j RETURN
iptables -w -N fw_app; iptables -w -A fw_app -m owner --uid-owner 10099 -j DROP
iptables -w -A OUTPUT -j fw_app

UNBOUND_MAINT=600 sh "$MOD/ctl.sh" daemon >/dev/null 2>&1 &
wait_for 10 jump_present
iptables -w -t nat -I OUTPUT -j FW_APP
sleep 1
# Looking every poll uses iptables-save only: never the xtables lock.
_m=$(ncalls); sleep 3
assert_contains "polls read the nat table" "iptables-save -t nat" "$(calls_since "$_m")"
calls_since "$_m" | grep -Eq '^ip6?tables ' && fail "polls ran iptables (takes the lock)" || pass

# The IPv4 jump is checked at every poll (1 s here; maintenance far away).
_m=$(ncalls)
iptables -w -t nat -D OUTPUT -j UNBOUND_DNS
wait_for 4 jump_present && pass || fail "nat jump restored at the next poll"
# The jump comes back first; the log line follows once IPv6 is checked too.
wait_for 4 grep -q "redirect: put back our rules that were removed: iptables/UNBOUND_DNS" "$D/log/module.log" \
    && pass || fail "restore logged: $(tail -n 3 "$D/log/module.log")"
calls_since "$_m" | grep -Eq -- '-F UNBOUND_DOT|^ip6tables .*-F ' && fail "restore rebuilt rules that were still there" || pass
assert_eq "other app's nat chain untouched" "-p udp --dport 53 -j RETURN" "$(cat "$STUB_STATE/iptables/nat/FW_APP")"
assert_eq "other app's filter chain untouched" "-m owner --uid-owner 10099 -j DROP" "$(cat "$STUB_STATE/iptables/filter/fw_app")"
grep -qx -- '-j fw_app' "$STUB_STATE/iptables/filter/OUTPUT" && pass || fail "other app's jump kept"
grep -qx -- '-j FW_APP' "$STUB_STATE/iptables/nat/OUTPUT" && pass || fail "other app's nat jump kept"

# The rest (IPv6, DoT block) only at maintenance.
ip6tables -w -t nat -D OUTPUT -j UNBOUND_DNS
iptables -w -D OUTPUT -j UNBOUND_DOT
sleep 3
v6_jump_present && fail "ipv6 jump restored before maintenance" || pass
ctl stop >/dev/null
wait_for 10 daemon_gone
iptables -w -t nat -D OUTPUT -j FW_APP; iptables -w -t nat -F FW_APP; iptables -w -t nat -X FW_APP
iptables -w -D OUTPUT -j fw_app; iptables -w -F fw_app; iptables -w -X fw_app

UNBOUND_MAINT=2 sh "$MOD/ctl.sh" daemon >/dev/null 2>&1 &
wait_for 10 jump_present
sleep 1
_m=$(ncalls)
ip6tables -w -t nat -D OUTPUT -j UNBOUND_DNS
iptables -w -D OUTPUT -j UNBOUND_DOT
wait_for 6 v6_jump_present && pass || fail "ipv6 jump restored at maintenance"
wait_for 6 dot_jump_present && pass || fail "dot jump restored at maintenance"
calls_since "$_m" | grep -q -- '^iptables .*-t nat -F UNBOUND_DNS' && fail "ipv4 nat rebuilt although intact" || pass
ctl stop >/dev/null
wait_for 10 daemon_gone

# Without iptables-save the check falls back to iptables -C.
touch "$STUB_STATE/nosave"
UNBOUND_MAINT=600 sh "$MOD/ctl.sh" daemon >/dev/null 2>&1 &
wait_for 10 jump_present
sleep 1
iptables -w -t nat -D OUTPUT -j UNBOUND_DNS
wait_for 4 jump_present && pass || fail "nat jump restored without iptables-save"
assert_contains "status without iptables-save" '"redirect_active":true' "$(ctl status)"
ctl stop >/dev/null
wait_for 10 daemon_gone
rm -f "$STUB_STATE/nosave"

# --- disabling in the manager is noticed at once (inotifyd watches the folder) ---
if command -v toybox >/dev/null 2>&1; then
    UNBOUND_POLL=60 sh "$MOD/ctl.sh" daemon >/dev/null 2>&1 &
    wait_for 10 jump_present
    sleep 1
    touch "$MOD/disable"
    wait_for 3 daemon_gone && pass || fail "disable noticed within 3 s"
    rm -f "$MOD/disable"
    wait_for 5 jump_absent
else
    echo "note: toybox not installed; skipped the inotifyd check"
fi

# --- without inotifyd, disabling is still noticed within the 10 s fallback ---
touch "$STUB_STATE/no-inotifyd"
UNBOUND_POLL=60 sh "$MOD/ctl.sh" daemon >/dev/null 2>&1 &
wait_for 10 jump_present
sleep 1
touch "$MOD/disable"
wait_for 14 daemon_gone && pass || fail "disable noticed within the fallback interval"
assert_contains "fallback logged" "checking for disable every 10 s" "$(cat "$D/log/module.log")"
rm -f "$MOD/disable" "$STUB_STATE/no-inotifyd"

done_testing
