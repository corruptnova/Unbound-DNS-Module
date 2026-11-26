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
  update-lists [--force] [--bg]
                             download due (or all) lists and rebuild
  rebuild                    rebuild from cached lists and reload Unbound
  set refresh_hours N        list refresh interval, 1-168 hours
  log [module|unbound] [N]   last N log lines (default 200)

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
        _q="$(printf '%s\n' "$_stats" | sed -n 's/^total\.num\.queries=//p')"
        _hits="$(printf '%s\n' "$_stats" | sed -n 's/^total\.num\.cachehits=//p')"
        _up="$(printf '%s\n' "$_stats" | sed -n 's/^time\.up=\([0-9]*\).*/\1/p')"
        _mem="$(sed -n 's/^VmRSS:[[:space:]]*\([0-9]*\).*/\1/p' "/proc/$_pid/status" 2>/dev/null)"
    else
        _err="$(grep -v '^[[:space:]]*$' "$VAR/unbound.stderr" 2>/dev/null | tail -n 1)"
    fi
    _act=0; redirect_active && _act=1
    _v6="$(cat "$RUN/redirect.v6" 2>/dev/null)"
    _pd="$(settings get global private_dns_mode 2>/dev/null)"
    printf '{"running":%s,"daemon":%s,"pid":%s,' "$(json_bool $_run)" \
        "$(daemon_running && echo true || echo false)" "$(json_num "$_pid")"
    printf '"redirect_enabled":%s,"redirect_active":%s,"ipv6":"%s",' \
        "$(json_bool "$(setting_get REDIRECT 1)")" "$(json_bool $_act)" "$(json_esc "${_v6:-}")"
    printf '"private_dns":"%s","version":"%s","module_version":"%s",' \
        "$(json_esc "$_pd")" "$(json_esc "$(unbound_version)")" "$(json_esc "$(module_version)")"
    printf '"queries":%s,"cache_hits":%s,"uptime":%s,"memory_kb":%s,' \
        "$(json_num "$_q")" "$(json_num "$_hits")" "$(json_num "$_up")" "$(json_num "$_mem")"
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
    printf '],"allow":['
    _first=1
    [ -f "$ALLOW" ] && while read -r _d; do
        [ -n "$_d" ] || continue
        [ $_first = 1 ] || printf ','
        _first=0
        printf '"%s"' "$(json_esc "$_d")"
    done < "$ALLOW"
    printf '],"local_dir":"%s"}\n' "$(json_esc "$LOCAL_LISTS")"
}

remove_and_rebuild() { source_remove "$1" && lists_rebuild; }

# allow_edit add|remove DOMAIN, then rebuild (caller holds the update lock).
allow_edit() {
    if [ "$1" = add ]; then
        { cat "$ALLOW" 2>/dev/null; echo "$2"; } | LC_ALL=C sort -u > "$ALLOW.tmp"
    else
        grep -vx -- "$2" "$ALLOW" > "$ALLOW.tmp" 2>/dev/null
    fi
    mv -f "$ALLOW.tmp" "$ALLOW"
    log "allowlist: $1 $2"
    lists_rebuild
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
            unbound_running || break
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
        run_locked update 300 allow_edit "${cmd#allow-}" "$_d" ;;
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
            cat "$VAR/unbound.log.1" "$VAR/unbound.log" "$VAR/unbound.stderr" 2>/dev/null | tail -n "$_n"
        else
            cat "$MODLOG.1" "$MODLOG" 2>/dev/null | tail -n "$_n"
        fi ;;
    uninstall-cleanup)
        cmd_stop >/dev/null
        private_dns_restore ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 2 ;;
esac
