#!/system/bin/sh
# Unbound DNS module control script. Boot (service.sh), the manager's Action
# button and the WebUI all go through here. Run "ctl.sh help" for commands.

# The WebUI runs commands with /system/bin/sh; switch to the root manager's
# busybox so every script sees the same awk/sed/sort.
if [ -z "${UNBOUND_NO_BUSYBOX_REEXEC:-}" ] && [ -z "${UNBOUND_IN_BB:-}" ]; then
    for _bb in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
        if [ -x "$_bb" ]; then
            UNBOUND_IN_BB=1 ASH_STANDALONE=1 exec "$_bb" sh "$0" "$@"
        fi
    done
fi

UNBOUND_MODDIR="${UNBOUND_MODDIR:-$(cd "${0%/*}" && pwd)}"
. "$UNBOUND_MODDIR/lib/common.sh"
. "$LIB_DIR/lists.sh"
. "$LIB_DIR/redirect.sh"
. "$LIB_DIR/settings.sh"
. "$LIB_DIR/daemon.sh"
umask 022

usage() {
    cat <<'EOF'
usage: ctl.sh <command> [args]

  status                     JSON status
  start | stop | restart     control the supervisor / Unbound
  redirect on|off|toggle     send all DNS to Unbound, or not
  lists                      JSON of blocklists and allowlist
  list-add URL [NAME]        add an https blocklist URL
  list-remove ID             remove a blocklist
  list-enable ID 0|1         disable / enable a blocklist
  allow-add DOMAIN           never block DOMAIN (and its subdomains)
  allow-remove DOMAIN
  block-add DOMAIN           always block DOMAIN and its subdomains (*.DOMAIN works too)
  block-remove DOMAIN
  update-lists [--force] [--bg]
                             download due (or all) lists and rebuild
  rebuild                    rebuild from cached lists and reload Unbound
  set refresh_hours N        list refresh interval, 1-168 hours
  settings                   JSON of Unbound settings and trust anchor state
  settings-apply KEY=VALUE...
                             change settings, restart Unbound, roll back if it
                             does not come up (FORWARDERS=addr[@port]#name,...)
  settings-reset             all settings back to defaults
  custom-get | custom-set BASE64
                             read / replace custom.conf (rolled back on error)
  anchor-update | anchor-reset
                             refresh the DNSSEC root trust anchor / restore
                             the built-in one
  log [module|unbound] [N]   last N log lines (default 200)
  selinux-report             Unbound's SELinux domain and accesses logged for it
  diag                       troubleshooting report (paste it into a bug report)
  stats-reset                start the query statistics from zero

  setup | daemon | uninstall-cleanup   used by the module itself
EOF
}

wake_daemon() { daemon_running && kill -USR1 "$(cat "$RUN/daemon.pid")" 2>/dev/null; }

# run_locked NAME TIMEOUT CMD...: wait for a lock, then run CMD.
run_locked() {
    _n="$1"; _w="$2"; shift 2
    _t=0
    until lock "$_n"; do
        [ "$_t" -ge "$_w" ] && die "busy: another list update is running"
        sleep 1; _t=$((_t + 1))
    done
    "$@"; _rc=$?
    unlock "$_n"
    return $_rc
}

status_json() {
    _run=0; _pid=""; _q=0; _hits=0; _up=0; _mem=0; _err=""
    if unbound_running; then
        _run=1; _pid="$(unbound_pid)"
        _stats="$(ubctl stats_noreset 2>/dev/null)"
        _q="$(json_num "$(printf '%s\n' "$_stats" | sed -n 's/^total\.num\.queries=//p')")"
        _hits="$(json_num "$(printf '%s\n' "$_stats" | sed -n 's/^total\.num\.cachehits=//p')")"
        _up="$(printf '%s\n' "$_stats" | sed -n 's/^time\.up=\([0-9]*\).*/\1/p')"
        _mem="$(sed -n 's/^VmRSS:[[:space:]]*\([0-9]*\).*/\1/p' "/proc/$_pid/status" 2>/dev/null)"
    fi
    # The last failed start, kept through retries until a start succeeds.
    _err="$(cat "$RUN/start_error" 2>/dev/null)"
    _act=0; redirect_active && _act=1
    _v6="$(cat "$RUN/redirect.v6" 2>/dev/null)"
    _pd="$(settings get global private_dns_mode 2>/dev/null)"
    printf '{"running":%s,"daemon":%s,"pid":%s,' "$(json_bool $_run)" \
        "$(daemon_running && echo true || echo false)" "$(json_num "$_pid")"
    printf '"redirect_enabled":%s,"redirect_active":%s,"ipv6":"%s",' \
        "$(json_bool "$(setting_get REDIRECT 1)")" "$(json_bool $_act)" "$(json_esc "${_v6:-}")"
    printf '"resolver":"%s","resolver_label":"%s",' "$(json_esc "$(opt RESOLVER)")" \
        "$(json_esc "$(resolver_label "$(opt RESOLVER)")")"
    printf '"nat64_bypass_v4":"%s","nat64_bypass_v6":"%s",' \
        "$(json_esc "$(cat "$RUN/nat64.iptables" 2>/dev/null)")" \
        "$(json_esc "$(cat "$RUN/nat64.ip6tables" 2>/dev/null)")"
    _se=""; [ "$_run" = 1 ] && _se="$(cat "$RUN/selinux" 2>/dev/null)"
    printf '"selinux":"%s",' "$(json_esc "$_se")"
    printf '"private_dns":"%s","version":"%s","module_version":"%s",' \
        "$(json_esc "$_pd")" "$(json_esc "$(unbound_version)")" "$(json_esc "$(module_version)")"
    # Saved totals plus what Unbound counted since the last snapshot.
    printf '"queries":%s,"cache_hits":%s,"stats_since":%s,"uptime":%s,"memory_kb":%s,' \
        "$(( $(stat_get QUERIES) + $(json_num "$_q") ))" "$(( $(stat_get CACHE_HITS) + $(json_num "$_hits") ))" \
        "$(stat_get SINCE)" "$(json_num "$_up")" "$(json_num "$_mem")"
    printf '"blocked":%s,"updating":%s,"last_update":%s,"last_update_ok":%s,' \
        "$(json_num "$(cat "$BLOCK_COUNT" 2>/dev/null)")" "$(locked update && echo true || echo false)" \
        "$(json_num "$(setting_get LAST_UPDATE 0)")" "$(json_bool "$(setting_get LAST_UPDATE_OK 1)")"
    printf '"refresh_hours":%s,"error":"%s"}\n' \
        "$(json_num "$(setting_get REFRESH_HOURS 24)")" "$(json_esc "$_err")"
}

lists_json() {
    printf '{"sources":['
    _first=1
    if [ -f "$SOURCES" ]; then
        while IFS="$TAB" read -r _id _en _name _url; do
            [ -n "$_id" ] || continue
            [ $_first = 1 ] || printf ','
            _first=0
            printf '{"id":"%s","enabled":%s,"name":"%s","url":"%s",' \
                "$(json_esc "$_id")" "$(json_bool "$_en")" "$(json_esc "$_name")" "$(json_esc "$_url")"
            printf '"updated":%s,"status":"%s","message":"%s","count":%s}' \
                "$(json_num "$(meta_get "$_id" updated)")" "$(json_esc "$(meta_get "$_id" status)")" \
                "$(json_esc "$(meta_get "$_id" message)")" "$(json_num "$(meta_get "$_id" count)")"
        done < "$SOURCES"
    fi
    printf '],"local":['
    _first=1
    for _f in "$LOCAL_LISTS"/*; do
        [ -f "$_f" ] || continue
        lists_parse "$_f" "$RUN/local.count" 2>/dev/null
        [ $_first = 1 ] || printf ','
        _first=0
        printf '{"file":"%s","count":%s}' "$(json_esc "${_f##*/}")" \
            "$(json_num "$(grep -c '^B ' "$RUN/local.count" 2>/dev/null)")"
    done
    rm -f "$RUN/local.count"
    printf '],"allow":'
    json_lines "$ALLOW"
    printf ',"block":'
    json_lines "$OWN_BLOCK"
    printf ',"local_dir":"%s"}\n' "$(json_esc "$LOCAL_LISTS")"
}



# --- applying settings safely --------------------------------------------------

APPLY_FILES="$SETTINGS $FORWARDERS $DATA/custom.conf"   # plus root.key, see below

backup_files() {
    rm -rf "$RUN/backup"; mkdir -p "$RUN/backup"
    for _f in $APPLY_FILES; do
        if [ -f "$_f" ]; then cp -p "$_f" "$RUN/backup/${_f##*/}"
        else : > "$RUN/backup/${_f##*/}.absent"; fi
    done
    ub_read root.key > "$RUN/backup/root.key" 2>/dev/null || rm -f "$RUN/backup/root.key"
}

restore_files() {
    for _f in $APPLY_FILES; do
        _b="$RUN/backup/${_f##*/}"
        if [ -f "$_b.absent" ]; then rm -f "$_f"
        elif [ -f "$_b" ]; then cp -p "$_b" "$_f"; fi
    done
    if [ -s "$RUN/backup/root.key" ]; then install_root_key "$RUN/backup/root.key"; fi
}

# regenerate: rebuild generated config from the stored settings.
regenerate() {
    write_runtime_conf
    write_options_conf
    [ "${_rebuild:-0}" = 1 ] && run_locked update 300 lists_rebuild noreload
    return 0
}

# restart_and_wait: restart Unbound through the supervisor and wait until it
# answers (with the redirect back, if enabled). Fails early if it cannot start.
restart_and_wait() {
    _mark="$(wc -l < "$MODLOG" 2>/dev/null)"
    touch "$RUN/restart"
    stop_unbound
    wake_daemon
    _t=0
    while [ "$_t" -lt "${UNBOUND_APPLY_TIMEOUT:-30}" ]; do
        if unbound_running && ubctl status >/dev/null 2>&1; then
            if [ "$(setting_get REDIRECT 1)" != 1 ] || redirect_active; then return 0; fi
        fi
        if tail -n +"$(( ${_mark:-0} + 1 ))" "$MODLOG" 2>/dev/null \
                | grep -q 'unbound: failed to start\|unbound: not ready'; then
            return 1
        fi
        sleep 1; _t=$((_t + 1))
    done
    return 1
}

# apply_with_rollback WHAT: the caller has backed up and changed files.
# Prints a JSON result; on failure the previous files are restored.
apply_with_rollback() {
    regenerate
    if ! daemon_running; then
        rm -rf "$RUN/backup"
        log "settings: saved ($1); used when Unbound next starts"
        printf '{"ok":true,"applied":false}\n'
        return 0
    fi
    if restart_and_wait; then
        rm -rf "$RUN/backup"
        log "settings: applied ($1)"
        printf '{"ok":true,"applied":true}\n'
        return 0
    fi
    _err="$(cat "$RUN/start_error" 2>/dev/null)"
    log "settings: $1 failed: ${_err:-Unbound did not answer}; restoring the previous settings"
    restore_files
    regenerate
    restart_and_wait || log "settings: Unbound did not come back after restoring; see the log"
    rm -rf "$RUN/backup"
    printf '{"ok":false,"error":"%s"}\n' "$(json_esc "Not applied: ${_err:-Unbound did not answer with these settings}. The previous settings are back.")"
    return 1
}

# settings-apply KEY=VALUE...: validate everything first, write nothing on error.
cmd_settings_apply() {
    [ $# -gt 0 ] || die "usage: settings-apply KEY=VALUE..."
    _fw=""; _fwset=0; _newres=""; _newmin=""; _newmax=""
    for _kv in "$@"; do
        case "$_kv" in *=*) ;; *) die "expected KEY=VALUE, got: $_kv" ;; esac
        _k="${_kv%%=*}"; _v="${_kv#*=}"
        no_newline "$_v" || die "invalid value for $_k"
        if [ "$_k" = FORWARDERS ]; then
            _fwset=1; _n=0
            _list="$(printf '%s' "$_v" | tr ',' '\n')"
            while IFS= read -r _f; do
                [ -n "$_f" ] || continue
                valid_forwarder "$_f" || die "invalid server: $_f (use address#tls-name, e.g. 9.9.9.9#dns.quad9.net)"
                _n=$((_n + 1))
            done <<FWLIST
$_list
FWLIST
            [ "$_n" -le 8 ] || die "at most 8 servers"
            _fw="$_v"
            continue
        fi
        is_setting_key "$_k" || die "unknown setting: $_k"
        setting_valid "$_k" "$_v" || die "invalid value for $_k: $_v"
        case "$_k" in
            RESOLVER) _newres="$_v" ;;
            CACHE_MIN_TTL) _newmin="$_v" ;;
            CACHE_MAX_TTL) _newmax="$_v" ;;
        esac
    done
    [ "${_newmin:-$(opt CACHE_MIN_TTL)}" -le "${_newmax:-$(opt CACHE_MAX_TTL)}" ] \
        || die "the minimum cache time must not be above the maximum"
    if [ "${_newres:-$(opt RESOLVER)}" = custom ]; then
        if [ "$_fwset" = 1 ]; then [ -n "$_fw" ] || die "add at least one server"
        else [ -s "$FORWARDERS" ] || die "add at least one server"; fi
    fi
    run_locked apply 120 _do_settings_apply "$@"
}

_do_settings_apply() {
    _oldblock="$(opt BLOCK_ANSWER)"
    backup_files
    for _kv in "$@"; do
        _k="${_kv%%=*}"; _v="${_kv#*=}"
        if [ "$_k" = FORWARDERS ]; then
            printf '%s\n' "$_v" | tr ',' '\n' | grep -v '^$' > "$FORWARDERS.tmp"
            mv -f "$FORWARDERS.tmp" "$FORWARDERS"
            continue
        fi
        if [ "$_v" = "$(setting_default "$_k")" ]; then setting_set "$_k" ""
        else setting_set "$_k" "$_v"; fi
    done
    _rebuild=0
    [ "$(opt BLOCK_ANSWER)" != "$_oldblock" ] && _rebuild=1
    apply_with_rollback "$*"
}

_do_settings_reset() {
    _oldblock="$(opt BLOCK_ANSWER)"
    backup_files
    for _k in $SETTING_KEYS; do setting_set "$_k" ""; done
    rm -f "$FORWARDERS"
    _rebuild=0
    [ "$(opt BLOCK_ANSWER)" != "$_oldblock" ] && _rebuild=1
    apply_with_rollback "reset to defaults"
}

cmd_custom_set() {
    [ -n "${1:-}" ] || die "usage: custom-set BASE64"
    [ "${#1}" -le 90000 ] || die "custom.conf is too large (64 KB at most)"
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9+/=]+$' || die "invalid encoding"
    printf '%s' "$1" | base64 -d > "$RUN/custom.new" 2>/dev/null || die "invalid encoding"
    [ "$(wc -c < "$RUN/custom.new")" -le 65536 ] || die "custom.conf is too large (64 KB at most)"
    [ "$(tr -d '\000' < "$RUN/custom.new" | wc -c)" = "$(wc -c < "$RUN/custom.new")" ] \
        || die "custom.conf must be text"
    run_locked apply 120 _do_custom_set
}

_do_custom_set() {
    backup_files
    cp -f "$RUN/custom.new" "$DATA/custom.conf"
    rm -f "$RUN/custom.new"
    chown 0:"$UB_UID" "$DATA/custom.conf" 2>/dev/null
    chmod 0640 "$DATA/custom.conf"
    _rebuild=0
    apply_with_rollback "custom.conf"
}

# anchor-update: ask IANA for the current root trust anchor. unbound-anchor
# resolves through the running Unbound (port 5335), so it works whether or
# not the redirect is on.
cmd_anchor_update() {
    unbound_running || die "Unbound is not running"
    ub_read root.key > "$RUN/anchor.key" 2>/dev/null && [ -s "$RUN/anchor.key" ] \
        || cp -f "$MODDIR/conf/root.key" "$RUN/anchor.key"
    printf 'server:\n    do-not-query-localhost: no\nforward-zone:\n    name: "."\n    forward-addr: 127.0.0.1@%s\n' \
        "$UB_PORT" > "$RUN/anchor.conf"
    _out="$("$BIN/unbound-anchor" -v -a "$RUN/anchor.key" -C "$RUN/anchor.conf" 2>&1)"
    case "$_out" in
        *"success: the anchor is ok"*)
            log "trust anchor: up to date"
            printf '{"ok":true,"changed":false}\n'
            return 0 ;;
        *"success:"*) ;;
        *)
            _e="$(printf '%s\n' "$_out" | grep -v '^[[:space:]]*$' | tail -n 1)"
            log "trust anchor: update failed: $_e"
            printf '{"ok":false,"error":"%s"}\n' "$(json_esc "Update failed: ${_e:-no answer from unbound-anchor}")"
            return 1 ;;
    esac
    run_locked apply 120 _do_anchor_install "$RUN/anchor.key" "trust anchor updated"
}

# _do_anchor_install FILE WHAT
_do_anchor_install() {
    backup_files
    install_root_key "$1"
    _rebuild=0
    apply_with_rollback "$2"
}

remove_and_rebuild() { source_remove "$1" && lists_rebuild; }

# list_edit FILE LABEL add|remove DOMAIN, then rebuild (caller holds the
# update lock). Used for the allowlist and the own blocklist.
list_edit() {
    if [ "$3" = add ]; then
        { cat "$1" 2>/dev/null; echo "$4"; } | LC_ALL=C sort -u > "$1.tmp"
    else
        grep -vx -- "$4" "$1" > "$1.tmp" 2>/dev/null
    fi
    mv -f "$1.tmp" "$1"
    log "$2: $3 $4"
    lists_rebuild
}

# diag: everything needed to see where DNS stops, as plain text.
cmd_diag() {
    _sec() { printf '\n== %s\n' "$1"; }
    echo "Unbound DNS module diagnostics, $(date '+%Y-%m-%d %H:%M:%S %z')"
    _sec "device"
    echo "module $(module_version), unbound $(unbound_version)"
    echo "android $(getprop ro.build.version.release 2>/dev/null) (sdk $(getprop ro.build.version.sdk 2>/dev/null)), $(getprop ro.product.model 2>/dev/null), abi $(getprop ro.product.cpu.abi 2>/dev/null)"
    echo "kernel $(uname -r)"
    for _m in ksu ap magisk; do [ -d "/data/adb/$_m" ] && echo "root manager dir: /data/adb/$_m"; done
    _sec "status"
    status_json
    _sec "config in use"
    grep -E '^[[:space:]]*(interface|port|access-control|do-ip[46]|username|chroot):' "$CONF" "$DATA/runtime.conf" 2>/dev/null
    grep -vE '^[[:space:]]*(#|$)' "$OPTIONS_CONF" 2>/dev/null | sed 's/^/options.conf: /'
    grep -vE '^[[:space:]]*(#|$)' "$DATA/custom.conf" 2>/dev/null | sed 's/^/custom.conf: /'
    _sec "listening sockets (port $UB_PORT)"
    _hex="$(printf '%04X' "$UB_PORT")"
    for _f in /proc/net/udp /proc/net/udp6 /proc/net/tcp /proc/net/tcp6; do
        grep -i ":$_hex " "$_f" 2>/dev/null | awk -v f="${_f##*/}" '{print f, $2, "uid", $8}'
    done
    _sec "redirect rules (packet counters)"
    for _i in iptables ip6tables; do
        echo "-- $_i nat"
        "$_i" -w -t nat -L OUTPUT -v -n 2>&1 | head -n 6
        "$_i" -w -t nat -L "$NAT_CHAIN" -v -n 2>&1
        echo "-- $_i filter $DOT_CHAIN"
        "$_i" -w -L "$DOT_CHAIN" -v -n 2>&1
    done
    _sec "networks and their DNS servers"
    dumpsys connectivity 2>/dev/null | grep -oE 'ni\{[A-Z_]+[^}]*\}|InterfaceName: [^ ]+|DnsAddresses: \[[^]]*\]|PrivateDnsServerName: [^ ]+|UsePrivateDns: [a-z]+' | head -n 40
    echo "private_dns_mode: $(settings get global private_dns_mode 2>/dev/null)"
    _sec "NAT64 / 464XLAT (IPv6-only networks)"
    dumpsys connectivity 2>/dev/null | grep -oE 'Nat64Prefix: [^ ]+|v4-[a-z0-9_]+' | sort -u
    ip -4 addr 2>/dev/null | grep -E '^[0-9]+: v4-|inet 192\.0\.0\.' 
    _sec "unbound counters (since the last 5-minute snapshot; totals are in status)"
    if unbound_running; then
        ubctl stats_noreset 2>/dev/null | grep -E '^total\.(num\.queries|num\.cachehits|num\.cachemiss|requestlist\.(avg|max|exceeded))=|^unwanted\.|^num\.answer\.rcode\.|^num\.query\.(ipv6|tcp|udpout)'
    else
        echo "unbound not running"
    fi
    _sec "module log (last 40)"
    tail -n 40 "$MODLOG" 2>/dev/null
    _sec "SELinux"
    cmd_selinux_report
    _sec "unbound log (last 40)"
    tail -n 40 "$UBLOG" 2>/dev/null
}

# selinux-report: Unbound's SELinux domain and every kind of access logged
# for it so far (the learning stage's harvest, for writing enforcing rules).
cmd_selinux_report() {
    se_harvest
    _ctx="not running"
    if unbound_running; then
        _ctx="$(tr -d '\000' < "/proc/$(unbound_pid)/attr/current" 2>/dev/null)"
        [ -n "$_ctx" ] || _ctx="unknown"
    fi
    _st="$(cat "$RUN/selinux" 2>/dev/null)"
    echo "state: ${_st:-unknown}; Unbound's context: $_ctx"
    if [ -s "$RUN/selinux.fallback" ]; then
        echo "fell back because: $(cat "$RUN/selinux.fallback")"
    fi
    _n=0; [ -f "$SE_DENIALS" ] && _n="$(grep -c 'avc:' "$SE_DENIALS")"
    echo "kinds of access logged for unbound_dns: $_n"
    # The kernel drops audit messages beyond a few per second; a permissive
    # domain logs each kind once per boot, so a dropped one waits for a reboot.
    _lost="$(dmesg 2>/dev/null | grep -o 'audit_lost=[0-9]*' | tail -n 1)"
    [ -n "$_lost" ] && echo "audit messages the kernel dropped since boot (all apps): ${_lost#audit_lost=}"
    cat "$SE_DENIALS" 2>/dev/null
}

cmd_redirect() {
    case "$1" in
        on) _want=1 ;;
        off) _want=0 ;;
        toggle) if [ "$(setting_get REDIRECT 1)" = 1 ]; then _want=0; else _want=1; fi ;;
        *) die "usage: redirect on|off|toggle" ;;
    esac
    setting_set REDIRECT "$_want"
    if daemon_running; then
        wake_daemon
        _t=0
        while [ "$_t" -lt 10 ]; do
            if redirect_active; then _is=1; else _is=0; fi
            [ "$_is" = "$_want" ] && break
            # Without Unbound the redirect cannot come on; switching it off
            # never depends on Unbound, so keep waiting for that.
            [ "$_want" = 1 ] && ! unbound_running && break
            sleep 1; _t=$((_t + 1))
        done
    fi
    if redirect_active; then echo "redirect: on"; else echo "redirect: off"; fi
}

cmd_stop() {
    touch "$RUN/stop"
    if daemon_running; then
        kill "$(cat "$RUN/daemon.pid")" 2>/dev/null
        _t=0
        while daemon_running && [ "$_t" -lt 20 ]; do sleep 1; _t=$((_t + 1)); done
    fi
    # Whatever happened above, leave the phone with working DNS.
    redirect_remove
    stop_unbound
    rm -f "$RUN/daemon.pid"
    echo stopped
}

cmd_start() {
    setup_data
    rm -f "$RUN/stop"
    if daemon_running; then echo "already running"; return 0; fi
    nohup sh "$MODDIR/ctl.sh" daemon >/dev/null 2>&1 &
    echo started
}

[ -d "$RUN" ] || setup_data >/dev/null 2>&1

cmd="${1:-help}"
[ $# -gt 0 ] && shift
case "$cmd" in
    status) status_json ;;
    lists) lists_json ;;
    setup) setup_data ;;
    daemon) daemon_main ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    restart)
        touch "$RUN/restart"
        stop_unbound
        wake_daemon || cmd_start
        echo restarting ;;
    redirect) cmd_redirect "${1:-}" ;;
    list-add)
        valid_url "${1:-}" || die "invalid URL (https only, no spaces or quotes)"
        _name="${2:-}"
        if [ -z "$_name" ]; then
            _name="$(printf '%s' "$1" | sed 's|^https://||; s|[/:].*||' | cut -c1-48)"
        fi
        valid_name "$_name" || die "invalid name (letters, digits, spaces and ._()+- only)"
        source_exists "$(url_id "$1")" && die "that list is already added"
        run_locked update 300 source_add "$1" "$_name"; echo ;;
    list-remove)
        valid_id "${1:-}" || die "invalid list id"
        source_exists "$1" || die "no such list"
        run_locked update 300 remove_and_rebuild "$1" ;;
    list-enable)
        valid_id "${1:-}" || die "invalid list id"
        case "${2:-}" in 0|1) ;; *) die "usage: list-enable ID 0|1" ;; esac
        run_locked update 300 source_enable "$1" "$2"
        if [ "$2" = 1 ] && [ ! -f "$CACHE/$1.parsed" ]; then
            nohup sh "$MODDIR/ctl.sh" update-lists >/dev/null 2>&1 &
        else
            run_locked update 300 lists_rebuild
        fi ;;
    allow-add|allow-remove)
        _d="$(normalise_domain "${1:-}")" || die "invalid domain name"
        run_locked update 300 list_edit "$ALLOW" allowlist "${cmd#allow-}" "$_d" ;;
    block-add|block-remove)
        _d="$(normalise_domain "${1:-}")" \
            || die "invalid domain name (use example.com or *.example.com; partial patterns are not possible)"
        run_locked update 300 list_edit "$OWN_BLOCK" "own blocklist" "${cmd#block-}" "$_d" ;;
    update-lists)
        _force=0; _bg=0
        for _a in "$@"; do
            case "$_a" in --force) _force=1 ;; --bg) _bg=1 ;; *) die "unknown option $_a" ;; esac
        done
        if [ "$_bg" = 1 ]; then
            locked update && { echo "already updating"; exit 0; }
            if [ "$_force" = 1 ]; then
                nohup sh "$MODDIR/ctl.sh" update-lists --force >/dev/null 2>&1 &
            else
                nohup sh "$MODDIR/ctl.sh" update-lists >/dev/null 2>&1 &
            fi
            echo "update started"
        else
            lists_update "$_force"
        fi ;;
    rebuild) run_locked update 300 lists_rebuild ;;
    set)
        case "${1:-}" in
            refresh_hours)
                case "${2:-}" in ''|*[!0-9]*) die "hours must be a number" ;; esac
                [ "$2" -ge 1 ] && [ "$2" -le 168 ] || die "hours must be 1-168"
                setting_set REFRESH_HOURS "$2" ;;
            *) die "unknown setting" ;;
        esac ;;
    log)
        _which=module; _n=200
        for _a in "$@"; do
            case "$_a" in
                module|unbound) _which="$_a" ;;
                *[!0-9]*|'') die "usage: log [module|unbound] [N]" ;;
                *) _n="$_a" ;;
            esac
        done
        if [ "$_which" = unbound ]; then
            cat "$UBLOG.1" "$UBLOG" 2>/dev/null | tail -n "$_n"
        else
            cat "$MODLOG.1" "$MODLOG" 2>/dev/null | tail -n "$_n"
        fi ;;
    uninstall-cleanup)
        cmd_stop >/dev/null
        private_dns_restore ;;
    diag) cmd_diag ;;
    selinux-report) cmd_selinux_report ;;
    stats-reset) stats_reset && printf '{"ok":true}\n' ;;
    settings) settings_json ;;
    settings-apply) cmd_settings_apply "$@" ;;
    settings-reset) run_locked apply 120 _do_settings_reset ;;
    custom-get) cat "$DATA/custom.conf" 2>/dev/null ;;
    custom-set) cmd_custom_set "${1:-}" ;;
    anchor-update) cmd_anchor_update ;;
    anchor-reset) run_locked apply 120 _do_anchor_install "$MODDIR/conf/root.key" "trust anchor reset to built-in" ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 2 ;;
esac
