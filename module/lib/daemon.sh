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
        # Reach servers over IPv6 only if the phone has IPv6 and it is wanted.
        if [ -f "$_if6" ] && [ "$(opt UPSTREAM_IPV6)" = 1 ]; then
            echo "    do-ip6: yes"
        else
            echo "    do-ip6: no"
        fi
    } > "$DATA/runtime.conf"
}

# setup_data: create the data/chroot directory and refresh shipped config.
# Safe to run any number of times; never touches user files.
setup_data() {
    umask 022
    mkdir -p "$DATA" "$VAR" "$RUN" "$LOGDIR" "$LISTS" "$CACHE" "$LOCAL_LISTS"
    chmod 0700 "$RUN" "$LOGDIR" "$LISTS"
    chown "$UB_UID:$UB_UID" "$VAR" 2>/dev/null
    chmod 0750 "$VAR"
    migrate_var
    cp -f "$MODDIR/conf/unbound.conf" "$CONF"
    cp -f "$MODDIR/conf/control.conf" "$CTRL_CONF"
    [ -f "$DATA/custom.conf" ] || cp "$MODDIR/conf/custom.conf" "$DATA/custom.conf"
    [ -n "$(ub_read root.key 2>/dev/null)" ] || install_root_key "$MODDIR/conf/root.key"
    [ -f "$SOURCES" ] || : > "$SOURCES"
    [ -f "$ALLOW" ] || : > "$ALLOW"
    [ -f "$OWN_BLOCK" ] || : > "$OWN_BLOCK"
    [ -f "$STATS_FILE" ] || _stats_write 0 0 "$(now)"
    [ -f "$BLOCK_CONF" ] || printf 'server:\n' > "$BLOCK_CONF"
    [ -f "$BLOCK_COUNT" ] || echo 0 > "$BLOCK_COUNT"
    write_runtime_conf
    install_ca_bundle
    write_options_conf

    # Unbound chroots here and runs as uid/gid $UB_UID: it may read the
    # config files and write only var/, which holds nothing but root.key.
    # Everything else stays root-only, and root never follows anything the
    # Unbound user could have put in var/ (see ub_read, install_root_key).
    chown 0:"$UB_UID" "$DATA" "$CONF" "$CTRL_CONF" "$DATA/custom.conf" \
        "$DATA/runtime.conf" "$BLOCK_CONF" 2>/dev/null
    chmod 0750 "$DATA"
    chmod 0640 "$CONF" "$CTRL_CONF" "$DATA/custom.conf" "$DATA/runtime.conf" "$BLOCK_CONF"
}

# install_root_key SRC: make SRC (a root-only file) the trust anchor that
# Unbound keeps up to date. Prepared in run/ and renamed over var/root.key,
# so a link or folder left there is replaced, never followed.
install_root_key() {
    _new="$RUN/root.key.new"
    rm -f "$_new"
    cp "$1" "$_new" || return 1
    chown "$UB_UID:$UB_UID" "$_new" 2>/dev/null
    chmod 0644 "$_new"
    if ! mv -f -T "$_new" "$VAR/root.key" 2>/dev/null; then
        rm -rf "$VAR/root.key"
        mv -f "$_new" "$VAR/root.key"
    fi
}

# migrate_var: earlier versions kept logs and the control socket in var/.
# Old logs are read with the Unbound user's rights, then the names removed
# (rm never follows a link).
migrate_var() {
    for _o in module unbound; do
        [ -e "$LOGDIR/$_o.log" ] && continue
        { ub_read "$_o.log.1"; ub_read "$_o.log"; } > "$LOGDIR/$_o.log" 2>/dev/null
    done
    rm -f "$VAR/module.log" "$VAR/module.log.1" "$VAR/unbound.log" "$VAR/unbound.log.1" \
        "$VAR/unbound.stderr" "$VAR/unbound.sock"
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
# --- SELinux: Unbound in its own domain ------------------------------------------
#
# sepolicy.rule (loaded by the root manager at boot) defines unbound_dns and
# the types of its binary and its folder. This build keeps the domain
# permissive, the learning stage: nothing is blocked, and each kind of access
# the rules do not allow is logged once, so the rules of an enforcing domain
# can be written from real use. Without the policy (another root manager, or
# before the reboot after installing) Unbound runs as before, in the manager's
# domain, and its folder gets back the label all of /data/adb has.
SE_DOMAIN=unbound_dns
SE_MODE=learning
SE_DENIALS="$LOGDIR/selinux-denials.txt"
SE_FS="${UNBOUND_SELINUXFS:-/sys/fs/selinux}"
SE_DATA="u:object_r:${SE_DOMAIN}_data_file:s0"
SE_DATA_PLAIN="u:object_r:adb_data_file:s0"
SE_LABELLED="$DATA/selinux.labelled"

# se_known CONTEXT...: the loaded policy knows each context. The kernel checks
# a context written to selinuxfs; chcon is no test, as root may set unknown
# labels.
se_known() {
    [ -e "$SE_FS/context" ] || return 1
    for _c in "$@"; do
        printf '%s' "$_c" | cat 1<> "$SE_FS/context" 2>/dev/null || return 1
    done
}

# se_prepare: label the Unbound binary so it can enter its domain, and its
# folder so the domain can be kept to it. Fails when the policy does not have
# them (not loaded) or there is no runcon. New files in the folder take its
# label. -h: never follow a symbolic link (Unbound's user can write var/).
#
# Each label is written twice, through another one. A file the kernel looked
# at before the root manager added the module's types at boot (the label is
# still there from the boot before) stays "unlabeled" to the kernel until its
# label is written again, and BusyBox's chcon skips a file whose label already
# reads the same.
se_prepare() {
    [ -z "${UNBOUND_NO_SELINUX:-}" ] || return 1
    command -v runcon >/dev/null 2>&1 || return 1
    se_known "$SE_DATA" "u:r:$SE_DOMAIN:s0" || return 1
    chcon u:object_r:system_file:s0 "$BIN/unbound" 2>/dev/null
    chcon "u:object_r:${SE_DOMAIN}_exec:s0" "$BIN/unbound" 2>/dev/null || return 1
    : > "$SE_LABELLED"
    chcon -hR "$SE_DATA_PLAIN" "$DATA" 2>/dev/null
    chcon -hR "$SE_DATA" "$DATA" 2>/dev/null
}

# se_unlabel: Unbound runs in the manager's domain, so its folder needs no
# label of its own; without the module's policy that label would mean nothing.
se_unlabel() {
    [ -f "$SE_LABELLED" ] || return 0
    chcon -hR "$SE_DATA_PLAIN" "$DATA" 2>/dev/null && rm -f "$SE_LABELLED"
}

# se_round: denials are kept per version of the policy: a new one allows
# more, so the list from the one before moves to selinux-denials.txt.old.
se_round() {
    _sp="# policy $(cksum < "$MODDIR/sepolicy.rule" 2>/dev/null | cut -d' ' -f1)"
    if [ -s "$SE_DENIALS" ] && [ "$(head -n 1 "$SE_DENIALS")" != "$_sp" ]; then
        mv -f "$SE_DENIALS" "$SE_DENIALS.old"
    fi
    [ -s "$SE_DENIALS" ] || echo "$_sp" > "$SE_DENIALS"
}

# se_harvest: keep each kind of access logged for Unbound's domain, and by
# other domains to Unbound or its files, without pids, inode numbers or
# addresses. Permissive denials are logged once per kind and the kernel and
# logcat buffers roll over, so they are collected while they last.
se_harvest() {
    se_round
    { dmesg 2>/dev/null; logcat -d -b all 2>/dev/null; } \
        | grep -F -e "scontext=u:r:$SE_DOMAIN:" -e "tcontext=u:r:$SE_DOMAIN:" -e "tcontext=u:object_r:${SE_DOMAIN}_" \
        | LC_ALL=C awk -v known="$SE_DENIALS" '
            function key(s,    p, a, b, c) {
                p = s; sub(/^.*denied +\{ */, "", p); sub(/ *\}.*/, "", p)
                a = s; sub(/^.*scontext=/, "", a); sub(/ .*/, "", a)
                b = s; sub(/^.*tcontext=/, "", b); sub(/ .*/, "", b)
                c = s; sub(/^.*tclass=/, "", c); sub(/ .*/, "", c)
                return p "|" a "|" b "|" c
            }
            BEGIN { while ((getline l < known) > 0) seen[key(l)] = 1 }
            /avc: +denied/ {
                s = $0
                sub(/^.*avc: +/, "avc: ", s)
                gsub(/ (pid|ino|dev|ioctlcmd|faddr|fport|daddr|dest|saddr|rport|laddr)=[^ ]*/, "", s)
                gsub(/  +/, " ", s)
                k = key(s)
                if (!(k in seen)) { seen[k] = 1; print s }
            }' >> "$SE_DENIALS"
}

# start_unbound: in its own SELinux domain when the policy is there. If it
# cannot start that way but starts the old way, the domain is the problem:
# keep it out of the domain until the supervisor restarts, and say why.
start_unbound() {
    : >> "$UBLOG"
    if [ ! -f "$RUN/selinux.fallback" ] && se_prepare; then
        if _launch confined; then echo "$SE_MODE" > "$RUN/selinux"; return 0; fi
        _se_err="$(cat "$RUN/start_error" 2>/dev/null)"
        _launch || return 1
        printf '%s\n' "${_se_err:-unknown}" > "$RUN/selinux.fallback"
        echo fallback > "$RUN/selinux"
        log "selinux: Unbound could not start in its own domain (${_se_err:-unknown}); running it in the root manager's domain until the supervisor restarts"
        return 0
    fi
    se_unlabel
    _launch || return 1
    if [ -f "$RUN/selinux.fallback" ]; then echo fallback; else echo unconfined; fi > "$RUN/selinux"
}

# _launch [confined]: start Unbound in the foreground under us and wait until
# it answers on the control socket. Blocklist loading can take a while.
_launch() {
    # Unbound logs to stderr (see unbound.conf). Only what this start wrote
    # is looked at when it fails.
    _mark=$(( $(wc -c < "$UBLOG") + 1 ))
    if [ "${1:-}" = confined ]; then
        # "--" first: BusyBox's runcon (the one root managers' scripts get)
        # reads options after PROG too and would take Unbound's -d and -c;
        # toybox's skips the "--".
        runcon -- "u:r:$SE_DOMAIN:s0" "$BIN/unbound" -d -c "$CONF" >> "$UBLOG" 2>&1 &
    else
        "$BIN/unbound" -d -c "$CONF" >> "$UBLOG" 2>&1 &
    fi
    _ub=$!
    echo "$_ub" > "$RUN/unbound.pid"
    _t=0
    while [ "$_t" -lt "${UNBOUND_START_TIMEOUT:-90}" ]; do
        if ! alive "$_ub"; then
            wait "$_ub" 2>/dev/null
            _out="$(tail -c +"$_mark" "$UBLOG" | grep -v '^[[:space:]]*$')"
            log "unbound: failed to start: $(printf '%s\n' "$_out" | tail -n 3 | tr '\n' ' ')"
            # Kept until a start succeeds, for status and rollback messages.
            # Replaced in one step so a status read never sees it empty.
            [ -n "$_out" ] || _out="Unbound exited during start without a message"
            printf '%s\n' "$_out" | tail -n 2 | tr '\n' ' ' > "$RUN/start_error.new"
            mv -f "$RUN/start_error.new" "$RUN/start_error"
            rm -f "$RUN/unbound.pid"
            return 1
        fi
        if ubctl status >/dev/null 2>&1; then
            rm -f "$RUN/start_error"
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

# --- statistics that survive restarts -------------------------------------------
# Unbound zeroes its counters on every restart and reload. stats.conf keeps
# running totals: before anything that resets Unbound, and every 5 minutes,
# the counters are added to it. "unbound-control stats" (unlike
# stats_noreset) reads and zeroes in one step, so nothing is counted twice.

STATS_FILE="$DATA/stats.conf"

stat_get() { _sv="$(sed -n "s/^$1=//p" "$STATS_FILE" 2>/dev/null | tail -n 1)"; json_num "$_sv"; }

_stats_write() {
    printf 'QUERIES=%s\nCACHE_HITS=%s\nSINCE=%s\n' "$1" "$2" "$3" > "$STATS_FILE.tmp" \
        && mv -f "$STATS_FILE.tmp" "$STATS_FILE"
}

_stats_lock() {
    _sw=0
    until lock stats; do
        [ "$_sw" -ge 10 ] && return 1
        sleep 1; _sw=$((_sw + 1))
    done
}

stats_bank() {
    unbound_running || return 0
    _sb="$(ubctl stats 2>/dev/null)" || return 0
    _sq="$(json_num "$(printf '%s\n' "$_sb" | sed -n 's/^total\.num\.queries=//p')")"
    _sh="$(json_num "$(printf '%s\n' "$_sb" | sed -n 's/^total\.num\.cachehits=//p')")"
    _stats_lock || return 0
    _since="$(stat_get SINCE)"; [ "$_since" = 0 ] && _since="$(now)"
    _stats_write $(( $(stat_get QUERIES) + _sq )) $(( $(stat_get CACHE_HITS) + _sh )) "$_since"
    unlock stats
}

stats_reset() {
    stats_bank
    _stats_lock || return 1
    _stats_write 0 0 "$(now)"
    unlock stats
}

stop_unbound() {
    _ub="$(unbound_pid)"
    if alive "$_ub" unbound; then
        stats_bank
        ubctl stop >/dev/null 2>&1 || kill "$_ub" 2>/dev/null
        _t=0
        while alive "$_ub" && [ "$_t" -lt 10 ]; do sleep 1; _t=$((_t + 1)); done
        alive "$_ub" && kill -9 "$_ub" 2>/dev/null
    fi
    [ -n "$_ub" ] && wait "$_ub" 2>/dev/null
    # Drop the pid file only if it is still the one we stopped: the
    # supervisor reacts to the exit at once and may already have started a
    # new Unbound and written its pid.
    [ "$(unbound_pid)" = "$_ub" ] && rm -f "$RUN/unbound.pid"
    return 0
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

# rotate_logs: both live in the root-only log/ folder. Unbound keeps
# unbound.log open as its stderr, so that one is copied and emptied.
rotate_logs() {
    if [ -f "$MODLOG" ] && [ "$(wc -c < "$MODLOG")" -gt 524288 ]; then
        mv -f "$MODLOG" "$MODLOG.1"
    fi
    if [ -f "$UBLOG" ] && [ "$(wc -c < "$UBLOG")" -gt 524288 ]; then
        cp -f "$UBLOG" "$UBLOG.1" && : > "$UBLOG"
    fi
}

module_off() { [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; }

# --- supervisor -------------------------------------------------------------------
#
# Event-driven so it costs next to nothing while the phone is awake:
#   - Unbound is our child; when it exits, SIGCHLD wakes us at once.
#   - ctl.sh (WebUI, Action button) sends SIGUSR1 after changing anything.
#   - inotifyd watches the module folder and wakes us the moment the manager
#     creates "disable" or "remove". Without inotifyd we look every 10 s.
#   - Every UNBOUND_POLL seconds (30) we look for stop/disable flags (shell
#     builtins) and check that the redirect's jump is still in the small nat
#     table (one iptables-save, which takes no lock). Legacy iptables
#     announces no rule changes, so rules removed by something else can only
#     be found by looking; only the missing parts are put back.
#   - Every UNBOUND_MAINT seconds (300) we do the heavier checks: the IPv6
#     and DoT-block rules (the filter table is large), list refresh due,
#     statistics, logs.

# uptime_now: whole seconds since boot in $_now, without starting a process.
uptime_now() { read -r _upt _x < /proc/uptime; _now="${_upt%%.*}"; }

# proc_alive PID: the process exists and is not a zombie (builtins only).
proc_alive() {
    [ -n "$1" ] || return 1
    _st=""
    read -r _st < "/proc/$1/stat" 2>/dev/null || return 1
    case "$_st" in *") Z "*) return 1 ;; esac
    return 0
}

# child_alive: our Unbound child is running.
child_alive() { proc_alive "$_child"; }

# watch_start: run inotifyd (busybox or toybox) on the module folder; it
# sleeps in the kernel until a file is created ("n") or renamed into it ("y").
# The mask starts with a spare "n" because toybox 0.8.9 skips the first
# letter after ":".
watch_start() {
    UNBOUND_DAEMON_PID=$$ inotifyd "$LIB_DIR/notify.sh" "$MODDIR:nny" >/dev/null 2>&1 &
    _watch=$!
}

daemon_main() {
    setup_data
    if daemon_running; then echo "daemon already running" >&2; return 0; fi
    echo $$ > "$RUN/daemon.pid"
    rm -f "$RUN/stop" "$RUN/selinux.fallback"
    _stop=0
    trap '_stop=1' TERM INT
    trap ':' USR1                       # "something changed": look now
    trap ':' CHLD                       # Unbound or a list update exited: look now
    log "daemon: started ($(module_version), unbound $(unbound_version))"

    # Start from a clean slate: Unbound must be our own child, and rules
    # left behind by an earlier run must not point at nothing.
    stop_unbound
    redirect_remove

    _poll="${UNBOUND_POLL:-30}"
    _maint_every="${UNBOUND_MAINT:-300}"
    _child=""; _applied=0; _pd_done=0; _backoff=5; _next_try=0
    watch_start
    uptime_now; _next_maint="$_now"
    while [ "$_stop" = 0 ] && [ ! -f "$RUN/stop" ] && ! module_off; do
        uptime_now
        _maint=0; _started=0
        if [ "$_now" -ge "$_next_maint" ]; then
            _maint=1; _next_maint=$((_now + _maint_every))
        fi
        if [ -f "$RUN/restart" ]; then          # user asked: retry right away
            rm -f "$RUN/restart"
            _next_try=0; _backoff=5
        fi

        if ! child_alive; then
            [ -n "$_child" ] && wait "$_child" 2>/dev/null
            _child=""
            if [ "$_applied" = 1 ]; then
                redirect_remove; _applied=0
                log "redirect: removed because Unbound is not running"
            fi
            if [ "$_now" -ge "$_next_try" ]; then
                if start_unbound; then
                    read -r _child < "$RUN/unbound.pid"
                    _backoff=5; _started=1
                else
                    uptime_now
                    _next_try=$((_now + _backoff))
                    _backoff=$(( _backoff * 2 > 300 ? 300 : _backoff * 2 ))
                fi
            fi
        fi

        if child_alive; then
            setting_var REDIRECT 1
            if [ "$_sv" = 1 ]; then
                _scope=dns; [ "$_maint" = 1 ] && _scope=all
                if [ "$_applied" = 0 ]; then
                    redirect_apply && _applied=1
                elif redirect_missing "$_scope"; then
                    redirect_repair || _applied=0
                fi
                if [ "$_pd_done" = 0 ] && [ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ]; then
                    private_dns_disable && _pd_done=1
                fi
            elif [ "$_applied" = 1 ]; then
                redirect_remove; _applied=0
                log "redirect: off (turned off by user)"
            fi
            if [ "$_maint" = 1 ] && refresh_due; then
                log "lists: scheduled refresh"
                sh "$MODDIR/ctl.sh" update-lists >/dev/null 2>&1 &
            fi
        fi

        if [ "$_maint" = 1 ]; then
            rotate_logs
            stats_bank
        fi
        # Also right after a start, which logs the most new kinds of access.
        if [ "$_maint" = 1 ] || [ "$_started" = 1 ]; then
            _sem=""; read -r _sem < "$RUN/selinux" 2>/dev/null
            [ "$_sem" = learning ] && se_harvest
        fi

        # Checked just before sleeping: a child that exited during this pass
        # has already had its SIGCHLD and will not wake us again.
        if [ -n "$_watch" ] && ! proc_alive "$_watch"; then
            wait "$_watch" 2>/dev/null
            _watch=""
            [ "$_poll" -gt 10 ] && _poll=10
            log "daemon: inotifyd not available; checking for disable every $_poll s"
        fi

        # Sleep until the next poll, a retry is due, a signal arrives or a
        # child exits, whichever comes first.
        _wait="$_poll"
        if ! child_alive; then
            uptime_now
            _wait=$((_next_try - _now))
            [ "$_wait" -lt 1 ] && _wait=1
            [ "$_wait" -gt "$_poll" ] && _wait="$_poll"
        fi
        sleep "$_wait" &
        _sl=$!
        wait "$_sl" 2>/dev/null
        kill "$_sl" 2>/dev/null
    done

    if [ -n "$_watch" ]; then
        kill "$_watch" 2>/dev/null
        wait "$_watch" 2>/dev/null
    fi
    redirect_remove
    stop_unbound
    if module_off; then
        private_dns_restore
        log "daemon: module disabled or removed"
    fi
    rm -f "$RUN/daemon.pid" "$RUN/stop"
    log "daemon: stopped"
}
