# Paths, logging, settings and validation shared by every module script.
# shellcheck shell=sh

MODDIR="${UNBOUND_MODDIR:-/data/adb/modules/unbound-dns}"
DATA="${UNBOUND_DATA:-/data/adb/unbound}"
APPDATA="${UNBOUND_APPDATA:-/data/data}"
BIN="$MODDIR/bin"
LIB_DIR="$MODDIR/lib"

VAR="$DATA/var"            # owned by the Unbound user: root.key, unbound.log, socket
RUN="$DATA/run"            # root-only runtime state: pids, locks, flags
LISTS="$DATA/lists"
CACHE="$LISTS/cache"
LOCAL_LISTS="$LISTS/local"
SOURCES="$LISTS/sources.list"
ALLOW="$LISTS/allow.list"
SETTINGS="$DATA/settings.conf"
CONF="$DATA/unbound.conf"
CTRL_CONF="$DATA/control.conf"
BLOCK_CONF="$DATA/blocklist.conf"
BLOCK_COUNT="$DATA/blocklist.count"
MODLOG="$VAR/module.log"

UB_UID=3003                # "inet": network access on paranoid-network kernels
UB_PORT=5335
TAB="$(printf '\t')"
NL='
'

now() { date +%s; }

log() {
    [ -d "$VAR" ] || return 0
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$MODLOG" 2>/dev/null
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# setting_get KEY [DEFAULT]
setting_get() {
    _v=""
    [ -f "$SETTINGS" ] && _v="$(sed -n "s/^$1=//p" "$SETTINGS" | tail -n 1)"
    [ -n "$_v" ] && printf '%s' "$_v" || printf '%s' "${2:-}"
}

# setting_set KEY VALUE   (empty VALUE removes the key)
setting_set() {
    case "$1" in *[!A-Z0-9_]*|'') die "bad setting key" ;; esac
    case "$2" in *[!A-Za-z0-9._:/@+-]*) die "bad setting value" ;; esac
    _tmp="$SETTINGS.tmp.$$"
    { [ -f "$SETTINGS" ] && grep -v "^$1=" "$SETTINGS"; [ -n "$2" ] && printf '%s=%s\n' "$1" "$2"; } > "$_tmp"
    mv -f "$_tmp" "$SETTINGS"
}

# --- validation (never trust what the WebUI sends) ---------------------------

no_newline() { case "$1" in *"$NL"*) return 1 ;; esac; return 0; }

valid_url() {
    no_newline "$1" || return 1
    [ "${#1}" -le 2048 ] || return 1
    printf '%s\n' "$1" | grep -Eq '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~%/?=&+,@:-]*)?$'
}

valid_name() {
    no_newline "$1" || return 1
    printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9 ._()+-]{1,48}$'
}

valid_id() { printf '%s\n' "$1" | grep -Eq '^[0-9a-f]{12}$' && no_newline "$1"; }

# normalise_domain IN -> prints the canonical lowercase name, or fails.
# Uses the blocklist parser so the WebUI and lists agree on what is valid.
normalise_domain() {
    no_newline "$1" || return 1
    case "$1" in *[!A-Za-z0-9._-]*) return 1 ;; esac
    _d="$(printf '%s\n' "$1" | LC_ALL=C awk -v bom= -f "$LIB_DIR/blocklist.awk")"
    case "$_d" in "B "*) printf '%s' "${_d#B }" ;; *) return 1 ;; esac
}

json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037'; }

json_bool() { if [ "$1" = 1 ] || [ "$1" = true ]; then printf true; else printf false; fi; }

# json_num VALUE: digits or 0
json_num() { case "$1" in ''|*[!0-9]*) printf 0 ;; *) printf '%s' "$1" ;; esac; }

# --- processes ---------------------------------------------------------------

# alive PID [NAME]: process exists, is not a zombie, and (optionally) its
# command line contains NAME.
alive() {
    [ -n "$1" ] && [ -d "/proc/$1" ] || return 1
    grep -q '^State:[[:space:]]*Z' "/proc/$1/status" 2>/dev/null && return 1
    [ -z "${2:-}" ] && return 0
    tr '\000' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q -- "$2"
}

pidfile_alive() { [ -f "$1" ] && alive "$(cat "$1" 2>/dev/null)" "${2:-}"; }

unbound_pid() { cat "$RUN/unbound.pid" 2>/dev/null; }
unbound_running() { pidfile_alive "$RUN/unbound.pid" unbound; }
daemon_running() { pidfile_alive "$RUN/daemon.pid" ctl.sh; }

ubctl() { "$BIN/unbound-control" -c "$CTRL_CONF" "$@"; }

# lock NAME / unlock NAME: mkdir-based, stale locks (dead owner) are broken.
lock() {
    _l="$RUN/$1.lock"
    if mkdir "$_l" 2>/dev/null; then echo $$ > "$_l/pid"; return 0; fi
    if ! alive "$(cat "$_l/pid" 2>/dev/null)"; then
        rm -rf "$_l"
        mkdir "$_l" 2>/dev/null && { echo $$ > "$_l/pid"; return 0; }
    fi
    return 1
}
unlock() { rm -rf "$RUN/$1.lock"; }
locked() { [ -d "$RUN/$1.lock" ] && alive "$(cat "$RUN/$1.lock/pid" 2>/dev/null)"; }
