# Data directory setup, Private DNS handling and the supervisor loop.
# shellcheck shell=sh

module_version() { sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null; }
unbound_version() { sed -n 's/^unbound=\([^ ]*\).*/\1/p' "$BIN/BUILDINFO" 2>/dev/null; }

write_runtime_conf() {
    _if6="${UNBOUND_IF_INET6:-/proc/net/if_inet6}"
    {
        echo "# Generated at every start by ctl.sh; do not edit."
        echo "server:"
        echo "    interface: 127.0.0.1@$UB_PORT"
        if grep -Eq '^0{31}1 .* lo$' "$_if6" 2>/dev/null; then
            echo "    interface: ::1@$UB_PORT"
        fi
        if [ -f "$_if6" ]; then echo "    do-ip6: yes"; else echo "    do-ip6: no"; fi
    } > "$DATA/runtime.conf"
}

# setup_data: create the data/chroot directory and refresh shipped config.
# Safe to run any number of times; never touches user files.
setup_data() {
    umask 022
    mkdir -p "$DATA" "$VAR" "$RUN" "$LISTS" "$CACHE" "$LOCAL_LISTS"
    cp -f "$MODDIR/conf/unbound.conf" "$CONF"
    cp -f "$MODDIR/conf/control.conf" "$CTRL_CONF"
    [ -f "$DATA/custom.conf" ] || cp "$MODDIR/conf/custom.conf" "$DATA/custom.conf"
    [ -s "$VAR/root.key" ] || cp "$MODDIR/conf/root.key" "$VAR/root.key"
    [ -f "$SOURCES" ] || : > "$SOURCES"
    [ -f "$ALLOW" ] || : > "$ALLOW"
    [ -f "$BLOCK_CONF" ] || printf 'server:\n' > "$BLOCK_CONF"
    [ -f "$BLOCK_COUNT" ] || echo 0 > "$BLOCK_COUNT"
    write_runtime_conf

    # Unbound chroots here and runs as uid/gid $UB_UID: it may read the
    # config files and write only var/. Everything else stays root-only.
    chown 0:"$UB_UID" "$DATA" "$CONF" "$CTRL_CONF" "$DATA/custom.conf" \
        "$DATA/runtime.conf" "$BLOCK_CONF" 2>/dev/null
    chmod 0750 "$DATA"
    chmod 0640 "$CONF" "$CTRL_CONF" "$DATA/custom.conf" "$DATA/runtime.conf" "$BLOCK_CONF"
    chown -R "$UB_UID:$UB_UID" "$VAR" 2>/dev/null
    chmod 0750 "$VAR"
    chmod 0700 "$RUN" "$LISTS"
}

# --- Private DNS (DNS-over-TLS in Android settings) bypasses port 53 --------

private_dns_disable() {
    _mode="$(settings get global private_dns_mode 2>/dev/null)" || return 1
    [ -n "$_mode" ] || return 1
    [ "$_mode" = off ] && return 0
    if [ -z "$(setting_get PRIVATE_DNS_SAVED)" ]; then
        setting_set PRIVATE_DNS_SAVED "$_mode"
        _spec="$(settings get global private_dns_specifier 2>/dev/null)"
        case "$_spec" in ''|null) ;; *) setting_set PRIVATE_DNS_SAVED_SPEC "$_spec" ;; esac
    fi
    settings put global private_dns_mode off >/dev/null 2>&1 || return 1
    log "private dns: turned off (was $_mode); it would bypass Unbound"
}

private_dns_restore() {
    _mode="$(setting_get PRIVATE_DNS_SAVED)"
    [ -n "$_mode" ] || return 0
    _spec="$(setting_get PRIVATE_DNS_SAVED_SPEC)"
    [ -n "$_spec" ] && settings put global private_dns_specifier "$_spec" >/dev/null 2>&1
    if [ "$_mode" = null ]; then
        settings delete global private_dns_mode >/dev/null 2>&1
    else
        settings put global private_dns_mode "$_mode" >/dev/null 2>&1
    fi
    setting_set PRIVATE_DNS_SAVED ""
    setting_set PRIVATE_DNS_SAVED_SPEC ""
    log "private dns: restored to $_mode"
}

# --- Unbound process ------------------------------------------------------------

# start_unbound: launch in the foreground mode under us and wait until it
# answers on the control socket. Blocklist loading can take a while.
start_unbound() {
    : > "$VAR/unbound.stderr"
    "$BIN/unbound" -d -c "$CONF" >> "$VAR/unbound.stderr" 2>&1 &
    _ub=$!
    echo "$_ub" > "$RUN/unbound.pid"
    _t=0
    while [ "$_t" -lt "${UNBOUND_START_TIMEOUT:-90}" ]; do
        if ! alive "$_ub"; then
            wait "$_ub" 2>/dev/null
            log "unbound: failed to start: $(tail -n 3 "$VAR/unbound.stderr" | tr '\n' ' ')"
            rm -f "$RUN/unbound.pid"
            return 1
        fi
        if ubctl status >/dev/null 2>&1; then
            log "unbound: running (pid $_ub)"
            return 0
        fi
        sleep 1
        _t=$((_t + 1))
    done
    log "unbound: not ready after ${_t}s; stopping it"
    stop_unbound
    return 1
}

stop_unbound() {
    _ub="$(unbound_pid)"
    if alive "$_ub" unbound; then
        ubctl stop >/dev/null 2>&1 || kill "$_ub" 2>/dev/null
        _t=0
        while alive "$_ub" && [ "$_t" -lt 10 ]; do sleep 1; _t=$((_t + 1)); done
        alive "$_ub" && kill -9 "$_ub" 2>/dev/null
    fi
    [ -n "$_ub" ] && wait "$_ub" 2>/dev/null
    rm -f "$RUN/unbound.pid"
}

# --- scheduled list refresh -----------------------------------------------------

refresh_due() {
    grep -q "^[0-9a-f]*${TAB}1${TAB}" "$SOURCES" 2>/dev/null || return 1
    locked update && return 1
    _h="$(setting_get REFRESH_HOURS 24)"
    _interval=$((_h * 3600))
    # After a failed refresh, try again within the hour.
    [ "$(setting_get LAST_UPDATE_OK 1)" = 1 ] || [ "$_interval" -le 3600 ] || _interval=3600
    [ $(( $(now) - $(setting_get LAST_UPDATE 0) )) -ge "$_interval" ]
}

rotate_logs() {
    for _f in "$VAR/unbound.log" "$MODLOG"; do
        [ -f "$_f" ] || continue
        [ "$(wc -c < "$_f")" -gt 524288 ] || continue
        mv -f "$_f" "$_f.1"
        [ "$_f" = "$VAR/unbound.log" ] && unbound_running && ubctl log_reopen >/dev/null 2>&1
    done
}

module_off() { [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; }

# --- supervisor -------------------------------------------------------------------

daemon_main() {
    setup_data
    if daemon_running; then echo "daemon already running" >&2; return 0; fi
    echo $$ > "$RUN/daemon.pid"
    rm -f "$RUN/stop"
    _stop=0
    trap '_stop=1' TERM INT
    trap ':' USR1                       # "something changed": wake up now
    log "daemon: started ($(module_version), unbound $(unbound_version))"

    _backoff=5; _next_try=0; _tick=0; _pd_done=0
    while [ "$_stop" = 0 ] && [ ! -f "$RUN/stop" ] && ! module_off; do
        if [ -f "$RUN/restart" ]; then          # user asked: retry right away
            rm -f "$RUN/restart"
            _next_try=0; _backoff=5
        fi
        if ! unbound_running; then
            if redirect_active; then
                redirect_remove
                log "redirect: removed because Unbound is not running"
            fi
            if [ "$(now)" -ge "$_next_try" ]; then
                if start_unbound; then
                    _backoff=5
                else
                    _next_try=$(( $(now) + _backoff ))
                    _backoff=$(( _backoff * 2 > 300 ? 300 : _backoff * 2 ))
                fi
            fi
        fi

        if unbound_running; then
            if [ "$(setting_get REDIRECT 1)" = 1 ]; then
                redirect_active || redirect_apply
                if [ "$_pd_done" = 0 ] && [ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ]; then
                    private_dns_disable && _pd_done=1
                fi
            elif redirect_active; then
                redirect_remove
                log "redirect: off (turned off by user)"
            fi
            if refresh_due; then
                log "lists: scheduled refresh"
                sh "$MODDIR/ctl.sh" update-lists >/dev/null 2>&1 &
            fi
        fi

        [ $((_tick % 30)) = 0 ] && rotate_logs
        _tick=$((_tick + 1))
        sleep "${UNBOUND_POLL:-10}" &
        _sl=$!
        wait "$_sl" 2>/dev/null
        kill "$_sl" 2>/dev/null
    done

    redirect_remove
    stop_unbound
    if module_off; then
        private_dns_restore
        log "daemon: module disabled or removed"
    fi
    rm -f "$RUN/daemon.pid" "$RUN/stop"
    log "daemon: stopped"
}
