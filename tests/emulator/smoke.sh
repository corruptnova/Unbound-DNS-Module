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
set -euo pipefail

ZIP="$1"
BUSYBOX="${BUSYBOX:-/bin/busybox}"
MOD=/data/adb/modules/unbound-dns
FAILS=0

say() { printf '\n== %s\n' "$*"; }
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
sh_dev() { adb shell "$@" | tr -d '\r'; }
ctl() { sh_dev "/data/adb/ksu/bin/busybox sh $MOD/ctl.sh $*"; }

# wait_until SECONDS DESCRIPTION CMD...
wait_until() {
    local s="$1" what="$2"; shift 2
    for _ in $(seq 1 "$s"); do
        if "$@" >/dev/null 2>&1; then ok "$what"; return 0; fi
        sleep 1
    done
    bad "$what (after ${s}s)"; return 1
}

resolves() { sh_dev "ping -c 1 -W 2 $1 2>&1" | grep -q "^PING $1 ("; }
unresolvable() { sh_dev "ping -c 1 -W 2 $1 2>&1" | grep -qi "unknown host"; }
status_has() { ctl status | grep -q "$1"; }
redirect_active() { sh_dev "iptables -w -t nat -C OUTPUT -j UNBOUND_DNS && echo yes" | grep -q yes; }
redirect_inactive() { ! redirect_active; }

dump_logs() {
    say "logs"
    ctl status || true
    sh_dev "cat /data/adb/unbound/var/module.log; echo ---; tail -n 60 /data/adb/unbound/var/unbound.log; echo ---; cat /data/adb/unbound/var/unbound.stderr" || true
    sh_dev "iptables -w -t nat -S; ip6tables -w -t nat -S" || true
}
trap 'dump_logs' ERR

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
wait_until 30 "resolves www.google.com without the module" resolves www.google.com

say "start (service.sh)"
sh_dev "ASH_STANDALONE=1 /data/adb/ksu/bin/busybox sh $MOD/service.sh"
wait_until 90 "unbound running" status_has '"running":true'
wait_until 20 "redirect active" redirect_active
wait_until 20 "private dns switched off" sh -c "[ \"\$(adb shell settings get global private_dns_mode | tr -d '\r')\" = off ]"

say "privileges"
pid="$(ctl status | sed -n 's/.*"pid":\([0-9]*\).*/\1/p')"
uid="$(sh_dev "grep ^Uid: /proc/$pid/status" | awk '{print $2}')"
[ "$uid" = 3003 ] && ok "unbound runs as uid 3003" || bad "unbound uid is $uid"
root="$(sh_dev "readlink /proc/$pid/root")"
[ "$root" = /data/adb/unbound ] && ok "unbound is chrooted" || bad "unbound root is $root"

say "resolution goes through Unbound"
q0="$(ctl status | sed -n 's/.*"queries":\([0-9]*\).*/\1/p')"
wait_until 30 "apps resolve www.wikipedia.org through the redirect" resolves www.wikipedia.org
q1="$(ctl status | sed -n 's/.*"queries":\([0-9]*\).*/\1/p')"
[ "$q1" -gt "$q0" ] && ok "Unbound counted the queries ($q0 -> $q1)" || bad "query count did not grow ($q0 -> $q1)"
ctl status | grep -q '"ipv6":"ok"' && ok "IPv6 DNS redirected" || echo "note: IPv6 NAT not available on this image"

say "blocklist download over TLS on the device"
ctl list-add https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts "StevenBlack" >/dev/null
ctl update-lists && ok "list downloaded and applied" || bad "update-lists failed"
blocked="$(ctl status | sed -n 's/.*"blocked":\([0-9]*\).*/\1/p')"
[ "${blocked:-0}" -gt 10000 ] && ok "$blocked domains blocked" || bad "blocked count $blocked"
wait_until 15 "listed domain is blocked (doubleclick.net)" unresolvable doubleclick.net
ctl allow-add doubleclick.net >/dev/null
wait_until 15 "allowlisted domain resolves again" resolves doubleclick.net
resolves www.wikipedia.org && ok "unlisted domain still resolves" || bad "unlisted domain"

say "fail-safe"
sh_dev "kill -9 $pid"
wait_until 30 "Unbound restarted after being killed" sh -c "ctl_pid=\$(adb shell /data/adb/ksu/bin/busybox sh $MOD/ctl.sh status | tr -d '\r' | sed -n 's/.*\"pid\":\([0-9]*\).*/\1/p'); [ -n \"\$ctl_pid\" ] && [ \"\$ctl_pid\" != 0 ] && [ \"\$ctl_pid\" != $pid ]"
wait_until 20 "redirect back after restart" redirect_active
sh_dev "echo 'server:' >> /data/adb/unbound/custom.conf; echo '    this-is-not-an-option: yes' >> /data/adb/unbound/custom.conf"
ctl restart >/dev/null
wait_until 30 "redirect removed while Unbound cannot start" redirect_inactive
wait_until 30 "DNS keeps working with a broken config" resolves www.google.com
ctl status | grep -q '"error":"[^"]' && ok "status reports the start error" || bad "no start error in status"
sh_dev "sed -i '/this-is-not-an-option/d' /data/adb/unbound/custom.conf"
ctl restart >/dev/null
wait_until 60 "recovers once the config is fixed" redirect_active

say "redirect toggle (Action button)"
sh_dev "ASH_STANDALONE=1 /data/adb/ksu/bin/busybox sh $MOD/action.sh" | grep -q "redirect: off" && ok "action turns redirect off" || bad "action off"
redirect_inactive && ok "rules removed" || bad "rules still there"
sh_dev "ASH_STANDALONE=1 /data/adb/ksu/bin/busybox sh $MOD/action.sh" | grep -q "redirect: on" && ok "action turns redirect on" || bad "action on"

say "disable in manager"
sh_dev "touch $MOD/disable"
wait_until 30 "redirect removed when disabled" redirect_inactive
wait_until 10 "private dns restored" sh -c "[ \"\$(adb shell settings get global private_dns_mode | tr -d '\r')\" = opportunistic ]"
resolves www.google.com && ok "DNS works after disable" || bad "DNS after disable"

trap - ERR
if [ "$FAILS" -gt 0 ]; then
    dump_logs
    echo "emulator smoke test: $FAILS failed"
    exit 1
fi
echo "emulator smoke test: all passed"
