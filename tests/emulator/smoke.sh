#!/usr/bin/env bash
# Install the module zip on a running, rootable emulator (adb root) and check
# it end to end with real Android networking.
#
#   tests/emulator/smoke.sh dist/unbound-dns-*.zip
#
# Emulates KernelSU: busybox at /data/adb/ksu/bin/busybox, module in
# /data/adb/modules/unbound-dns, SELinux permissive like KernelSU's root
# domain. Needs a static x86_64 busybox on the host (BUSYBOX, default
# /bin/busybox from Ubuntu's busybox-static).
set -uo pipefail

ZIP="$1"
BUSYBOX="${BUSYBOX:-/bin/busybox}"
MOD=/data/adb/modules/unbound-dns
FAILS=0

say() { printf '\n== %s\n' "$*"; }
ok() { echo "ok   $*"; }
FAILED=""
bad() { echo "FAIL $*"; FAILS=$((FAILS + 1)); FAILED="$FAILED
  - $*"; }
sh_dev() { adb shell "$@" | tr -d '\r'; }
ctl() { sh_dev "/data/adb/ksu/bin/busybox sh $MOD/ctl.sh $*"; }

# wait_until SECONDS DESCRIPTION CMD...: records a failure but keeps going,
# so one run reports everything. Use `|| fatal` where nothing after can work.
wait_until() {
    local s="$1" what="$2" start=$SECONDS; shift 2
    while [ $((SECONDS - start)) -lt "$s" ]; do
        if "$@" >/dev/null 2>&1; then ok "$what"; return 0; fi
        sleep 1
    done
    bad "$what (after ${s}s)"; return 1
}
fatal() { dump_logs; echo "emulator smoke test: stopping, nothing after this can pass"; exit 1; }

net_diag() {
    say "network diagnostics"
    sh_dev "ping -c 1 -W 2 www.google.com 2>&1; echo exit=\$?" || true
    sh_dev "getprop | grep -iE 'dns|net\\.' | head -20" || true
    sh_dev "ip addr; ip route; ip rule" || true
    sh_dev "dumpsys connectivity | grep -iE 'NetworkAgentInfo|DnsAddresses|Dns ' | head -20" || true
    sh_dev "settings get global private_dns_mode" || true
}

# ping is only used to resolve a name the way apps do (getaddrinfo via netd).
# The emulator cannot ping out, so ping always "fails"; "; true" keeps that
# exit status from failing the pipeline under pipefail.
# ping prints the canonical name, e.g. "PING dyna.wikimedia.org (1.2.3.4)"
# for www.wikipedia.org, so accept any name followed by an address.
resolves() { sh_dev "ping -c 1 -W 2 $1 2>&1; true" | grep -qE '^PING [^ ]+ \([0-9a-fA-F.:]+\)'; }
unresolvable() { sh_dev "ping -c 1 -W 2 $1 2>&1; true" | grep -qiE "unknown host|no address|name or service"; }
status_has() { ctl status | grep -q "$1"; }
redirect_active() { sh_dev "iptables -w -t nat -C OUTPUT -j UNBOUND_DNS && echo yes" | grep -q yes; }
redirect_inactive() { ! redirect_active; }

dump_logs() {
    say "logs"
    ctl status || true
    sh_dev "cat /data/adb/unbound/log/module.log; echo ---; tail -n 60 /data/adb/unbound/log/unbound.log; echo ---; ls -la /data/adb/unbound/var" || true
    sh_dev "iptables -w -t nat -S; ip6tables -w -t nat -S" || true
}

say "prepare device"
adb wait-for-device
adb root >/dev/null; sleep 3; adb wait-for-device
until [ "$(sh_dev getprop sys.boot_completed)" = 1 ]; do sleep 2; done
sh_dev setenforce 0
sh_dev "settings put global private_dns_mode opportunistic"
sh_dev "mkdir -p /data/adb/ksu/bin /data/adb/modules"
adb push "$BUSYBOX" /data/adb/ksu/bin/busybox >/dev/null
sh_dev "chmod 0755 /data/adb/ksu/bin/busybox"

say "install like the KernelSU installer"
work="$(mktemp -d)"
unzip -q "$ZIP" -d "$work/unbound-dns"
sh_dev "rm -rf $MOD"
adb push "$work/unbound-dns" /data/adb/modules/ >/dev/null
abi="$(sh_dev getprop ro.product.cpu.abi)"
case "$abi" in x86_64) arch=x64 ;; arm64-v8a) arch=arm64 ;; *) arch=arm ;; esac
api="$(sh_dev getprop ro.build.version.sdk)"
sh_dev "cd $MOD && ARCH=$arch API=$api MODPATH=$MOD ASH_STANDALONE=1 /data/adb/ksu/bin/busybox sh -c '
    ui_print() { echo \"\$1\"; }
    abort() { echo \"\$1\"; exit 1; }
    set_perm() { chown \$2:\$3 \"\$1\"; chmod \$4 \"\$1\"; }
    set_perm_recursive() { find \"\$1\" -type d -exec chmod \$4 {} +; find \"\$1\" -type f -exec chmod \$5 {} +; }
    . ./customize.sh'"
sh_dev "test -x $MOD/bin/unbound" && ok "binaries for $abi installed" || bad "binaries installed"

say "baseline: emulator DNS works before the module starts"
wait_until 120 "resolves www.google.com without the module" resolves www.google.com || net_diag

say "start (service.sh)"
sh_dev "ASH_STANDALONE=1 /data/adb/ksu/bin/busybox sh $MOD/service.sh"
wait_until 90 "unbound running" status_has '"running":true' || fatal
wait_until 20 "redirect active" redirect_active
wait_until 20 "private dns switched off" sh -c "[ \"\$(adb shell settings get global private_dns_mode | tr -d '\r')\" = off ]"

say "privileges"
pid="$(ctl status | sed -n 's/.*"pid":\([0-9]*\).*/\1/p')"
[ -n "$pid" ] && [ "$pid" != 0 ] || fatal
uid="$(sh_dev "grep ^Uid: /proc/$pid/status" | awk '{print $2}')"
[ "$uid" = 3003 ] && ok "unbound runs as uid 3003" || bad "unbound uid is $uid"
root="$(sh_dev "readlink /proc/$pid/root")"
[ "$root" = /data/adb/unbound ] && ok "unbound is chrooted" || bad "unbound root is $root"
# The Unbound user can write only var/, and nothing there but root.key.
v="$(sh_dev "ls -A /data/adb/unbound/var" | grep -v '^root\.key\.')"
[ "$v" = root.key ] && ok "var/ holds only root.key" || bad "var/ holds: $v"
sh_dev "[ -S /data/adb/unbound/run/unbound.sock ] && echo yes" | grep -q yes \
    && ok "control socket in the root-only run/ folder" || bad "no control socket in run/"
sh_dev "grep -q 'start of service' /data/adb/unbound/log/unbound.log && echo yes" | grep -q yes \
    && ok "Unbound's log saved in log/" || bad "Unbound's log missing from log/"

say "resolution goes through Unbound"
q0="$(ctl status | sed -n 's/.*"queries":\([0-9]*\).*/\1/p')"
wait_until 30 "apps resolve www.wikipedia.org through the redirect" resolves www.wikipedia.org
echo "     lookup: $(sh_dev "ping -c 1 -W 2 www.wikipedia.org 2>&1; true" | head -n 1)"
q1="$(ctl status | sed -n 's/.*"queries":\([0-9]*\).*/\1/p')"
[ "$q1" -gt "$q0" ] && ok "Unbound counted the queries ($q0 -> $q1)" || bad "query count did not grow ($q0 -> $q1)"
ctl status | grep -q '"ipv6":"ok"' && ok "IPv6 DNS redirected" || echo "note: IPv6 NAT not available on this image"

say "NAT64 discovery bypass (ipv4only.arpa goes to the network's DNS64)"
if ctl status | grep -q '"nat64_bypass_v4":"ok"'; then
    ok "bypass rule installed on this kernel"
    nat64_count() { sh_dev "iptables -w -t nat -L UNBOUND_DNS -v -n -x" | awk '/STRING|ipv4only/ { print $1; exit }'; }
    c0="$(nat64_count)"
    sh_dev "ping -c 1 -W 2 ipv4only.arpa >/dev/null 2>&1; true"
    c1="$(nat64_count)"
    [ "${c1:-0}" -gt "${c0:-0}" ] && ok "ipv4only.arpa lookups bypass Unbound ($c0 -> $c1 packets)" \
        || bad "ipv4only.arpa lookups did not hit the bypass ($c0 -> $c1)"
    # The same bytes anywhere else in a query must not skip Unbound.
    sh_dev "ping -c 1 -W 2 x.ipv4only.arpa >/dev/null 2>&1; true"
    c2="$(nat64_count)"
    [ "${c2:-0}" = "${c1:-0}" ] && ok "a longer name ending in ipv4only.arpa goes to Unbound" \
        || bad "x.ipv4only.arpa hit the bypass ($c1 -> $c2)"
else
    bad "bypass rule not installed: $(ctl status | grep -o '"nat64_bypass_v4":"[a-z]*"')"
fi

say "lookups from a real app's uid (apps, not root, are what users run)"
# Run curl as an installed app's uid: getaddrinfo then goes through netd
# exactly as for that app (permission checks, socket owned by the app uid).
app_uid="$(sh_dev "pm list packages -U com.google.android.gms" | sed -n 's/.*uid:\([0-9]*\).*/\1/p' | head -n 1)"
if [ -n "$app_uid" ]; then
    sh_dev "cp $MOD/bin/curl /data/local/tmp/ubcurl && chmod 0755 /data/local/tmp/ubcurl"
    app_lookup() {
        # curl exit 6 = could not resolve; anything else means the name resolved.
        rc="$(sh_dev "su $app_uid /data/local/tmp/ubcurl -sS -m 10 -o /dev/null http://$1/ 2>&1; echo rc=\$?" | sed -n 's/^rc=//p')"
        echo "     app uid $app_uid lookup $1: curl exit $rc"
        [ -n "$rc" ] && [ "$rc" != 6 ]
    }
    q0="$(ctl status | sed -n 's/.*"queries":\([0-9]*\).*/\1/p')"
    wait_until 30 "app resolves www.example.com through Unbound" app_lookup www.example.com
    wait_until 30 "app resolves a CNAME (www.wikipedia.org)" app_lookup www.wikipedia.org
    q1="$(ctl status | sed -n 's/.*"queries":\([0-9]*\).*/\1/p')"
    [ "$q1" -gt "$q0" ] && ok "Unbound counted the app's queries ($q0 -> $q1)" || bad "app queries did not reach Unbound ($q0 -> $q1)"
else
    bad "no app uid found to test with"
fi
say "diagnostics while running"
ctl diag

say "blocklist download over TLS on the device"
ctl list-add https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts "StevenBlack" >/dev/null
ctl update-lists && ok "list downloaded and applied" || bad "update-lists failed"
blocked="$(ctl status | sed -n 's/.*"blocked":\([0-9]*\).*/\1/p')"
[ "${blocked:-0}" -gt 10000 ] && ok "$blocked domains blocked" || bad "blocked count $blocked"
wait_until 15 "listed domain is blocked (doubleclick.net)" unresolvable doubleclick.net
ctl allow-add doubleclick.net >/dev/null
wait_until 15 "allowlisted domain resolves again" resolves doubleclick.net
wait_until 15 "unlisted domain still resolves" resolves www.wikipedia.org

say "own blocklist"
ctl block-add '*.example.org' >/dev/null
wait_until 15 "own block applies (example.org)" unresolvable example.org
ctl block-remove example.org >/dev/null
wait_until 20 "removing it unblocks" resolves example.org

say "encrypted forwarding (Quad9, DNS-over-TLS) and back"
qa="$(ctl status | sed -n 's/.*"queries":\([0-9]*\).*/\1/p')"
out="$(ctl settings-apply RESOLVER=quad9)"
qb="$(ctl status | sed -n 's/.*"queries":\([0-9]*\).*/\1/p')"
[ "${qb:-0}" -ge "${qa:-1}" ] && [ "${qa:-0}" -gt 0 ] && ok "query totals survive the restart ($qa -> $qb)" \
    || bad "query totals dropped on restart ($qa -> $qb)"
echo "$out" | grep -q '"applied":true' && ok "switched to Quad9" || bad "switch to Quad9: $out"
q0="$(ctl status | sed -n 's/.*"queries":\([0-9]*\).*/\1/p')"
wait_until 30 "resolves through Quad9 over TLS" resolves www.wikimedia.org
q1="$(ctl status | sed -n 's/.*"queries":\([0-9]*\).*/\1/p')"
[ "${q1:-0}" -gt "${q0:-0}" ] && ok "Unbound answered ($q0 -> $q1)" || bad "no queries counted ($q0 -> $q1)"
dot="$(sh_dev "cat /proc/net/tcp /proc/net/tcp6" | awk '$3 ~ /:0355$/ && $8 == 3003' | wc -l)"
[ "$dot" -gt 0 ] && ok "Unbound has TLS connections to port 853" || bad "no connection to port 853 from Unbound"
out="$(ctl settings-apply RESOLVER=recursive)"
echo "$out" | grep -q '"applied":true' && ok "back to recursive" || bad "back to recursive: $out"
wait_until 30 "resolves recursively again" resolves www.mozilla.org

say "trust anchor"
out="$(ctl anchor-update)"
echo "     $out"
echo "$out" | grep -q '"ok":true' && ok "trust anchor checked with IANA" || bad "trust anchor update: $out"

say "settings rollback"
b64="$(printf 'server:\n    this-is-not-an-option: yes\n' | base64 | tr -d '\n')"
out="$(ctl custom-set "$b64")"
echo "$out" | grep -q '"ok":false' && ok "bad custom.conf refused" || bad "bad custom.conf: $out"
wait_until 30 "Unbound running again after rollback" status_has '"running":true'
sh_dev "grep -q this-is-not-an-option /data/adb/unbound/custom.conf" && bad "custom.conf not restored" || ok "custom.conf restored"
wait_until 20 "redirect back after rollback" redirect_active

say "fail-safe"
sh_dev "kill -9 $pid"
wait_until 30 "Unbound restarted after being killed" sh -c "ctl_pid=\$(adb shell /data/adb/ksu/bin/busybox sh $MOD/ctl.sh status | tr -d '\r' | sed -n 's/.*\"pid\":\([0-9]*\).*/\1/p'); [ -n \"\$ctl_pid\" ] && [ \"\$ctl_pid\" != 0 ] && [ \"\$ctl_pid\" != $pid ]"
wait_until 20 "redirect back after restart" redirect_active
sh_dev "echo 'server:' >> /data/adb/unbound/custom.conf; echo '    this-is-not-an-option: yes' >> /data/adb/unbound/custom.conf"
ctl restart >/dev/null
wait_until 30 "redirect removed while Unbound cannot start" redirect_inactive
wait_until 30 "DNS keeps working with a broken config" resolves www.google.com
# The error is recorded when the next start attempt fails, a moment after
# the redirect is removed.
status_has_error() { ctl status | grep -q '"error":"[^"]'; }
wait_until 20 "status reports the start error" status_has_error
sh_dev "sed -i '/this-is-not-an-option/d' /data/adb/unbound/custom.conf"
ctl restart >/dev/null
wait_until 60 "recovers once the config is fixed" redirect_active

say "redirect toggle (Action button)"
sh_dev "ASH_STANDALONE=1 /data/adb/ksu/bin/busybox sh $MOD/action.sh" | grep -q "redirect: off" && ok "action turns redirect off" || bad "action off"
redirect_inactive && ok "rules removed" || bad "rules still there"
sh_dev "ASH_STANDALONE=1 /data/adb/ksu/bin/busybox sh $MOD/action.sh" | grep -q "redirect: on" && ok "action turns redirect on" || bad "action on"

say "rules removed by something else"
# The supervisor looks with iptables-save (no xtables lock); make sure that
# sees the jump on Android.
sh_dev "iptables-save -t nat" | grep -qx -- "-A OUTPUT -j UNBOUND_DNS" \
    && ok "iptables-save shows the redirect jump" || bad "iptables-save does not show the jump"
sh_dev "iptables -w -t nat -D OUTPUT -j UNBOUND_DNS"
redirect_inactive && ok "redirect jump deleted" || bad "could not delete the jump"
wait_until 40 "redirect put back within a poll" redirect_active
restore_logged() { sh_dev "grep -c 'put back our rules that were removed: iptables/UNBOUND_DNS' /data/adb/unbound/log/module.log" | grep -qv '^0'; }
wait_until 10 "restore logged" restore_logged

say "disable in manager"
case "$(sh_dev "cat /data/adb/unbound/log/module.log")" in
    *"inotifyd not available"*) bad "inotifyd watcher did not start" ;;
    *) ok "inotifyd watcher running" ;;
esac
sh_dev "touch $MOD/disable"
wait_until 5 "redirect removed when disabled" redirect_inactive
wait_until 10 "private dns restored" sh -c "[ \"\$(adb shell settings get global private_dns_mode | tr -d '\r')\" = opportunistic ]"
resolves www.google.com && ok "DNS works after disable" || bad "DNS after disable"

if [ "$FAILS" -gt 0 ]; then
    net_diag
    dump_logs
    echo "emulator smoke test: $FAILS failed:$FAILED"
    exit 1
fi
echo "emulator smoke test: all passed"
