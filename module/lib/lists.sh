# Blocklist parsing and merging. Sourced; needs LIB_DIR.
# shellcheck shell=sh

# lists_parse IN OUT: normalise any supported list format to "B d"/"A d".
lists_parse() {
    LC_ALL=C awk -v bom="$(printf '\357\273\277')" -f "$LIB_DIR/blocklist.awk" "$1" > "$2.tmp" \
        && mv -f "$2.tmp" "$2"
}

# lists_merge OUTCONF COUNTFILE [BLOCKTYPE] < tagged lines
# Writes Unbound local-zone config and the blocked-zone count. BLOCKTYPE is
# always_nxdomain (default) or always_null (answer 0.0.0.0 / ::).
lists_merge() {
    LC_ALL=C awk '{ n = split($2, l, "."); r = l[n]
                    for (i = n - 1; i >= 1; i--) r = r "!" l[i]
                    print r " " $1 }' \
        | LC_ALL=C sort -u \
        | LC_ALL=C awk -v countfile="$2" -v blocktype="${3:-always_nxdomain}" -f "$LIB_DIR/merge.awk" > "$1"
}

# --- sources: lists/sources.list is "id<TAB>enabled<TAB>name<TAB>url" -------

url_id() { printf '%s' "$1" | md5sum | cut -c1-12; }

# meta_get ID KEY
meta_get() { sed -n "s/^$2=//p" "$CACHE/$1.meta" 2>/dev/null | tail -n 1; }

# meta_write ID key=value...
meta_write() {
    _id="$1"; shift
    printf '%s\n' "$@" > "$CACHE/$_id.meta.tmp" && mv -f "$CACHE/$_id.meta.tmp" "$CACHE/$_id.meta"
}

source_exists() { [ -f "$SOURCES" ] && cut -f1 "$SOURCES" | grep -qx "$1"; }

source_add() {
    _url="$1"; _name="$2"
    _id="$(url_id "$_url")"
    source_exists "$_id" && die "that list is already added"
    printf '%s\t1\t%s\t%s\n' "$_id" "$_name" "$_url" >> "$SOURCES"
    log "lists: added $_name ($_url)"
    printf '%s' "$_id"
}

source_remove() {
    source_exists "$1" || die "no such list"
    grep -v "^$1$TAB" "$SOURCES" > "$SOURCES.tmp"; mv -f "$SOURCES.tmp" "$SOURCES"
    rm -f "$CACHE/$1.parsed" "$CACHE/$1.meta"
    log "lists: removed $1"
}

source_enable() {
    source_exists "$1" || die "no such list"
    awk -F '\t' -v OFS='\t' -v id="$1" -v en="$2" '$1 == id { $2 = en } { print }' \
        "$SOURCES" > "$SOURCES.tmp" && mv -f "$SOURCES.tmp" "$SOURCES"
}

# --- downloading --------------------------------------------------------------

# Android's own CA store, concatenated for curl. The files hold a PEM block
# plus a text dump; OpenSSL skips the text.
ca_bundle() {
    _ca="$RUN/ca.pem"
    if [ ! -s "$_ca" ] || [ -n "$(find "$_ca" -mmin +1440 2>/dev/null)" ]; then
        for _d in /apex/com.android.conscrypt/cacerts /system/etc/security/cacerts; do
            if ls "$_d"/*.0 >/dev/null 2>&1; then
                cat "$_d"/*.0 > "$_ca.tmp" && mv -f "$_ca.tmp" "$_ca"
                break
            fi
        done
    fi
    [ -n "${UNBOUND_CA_BUNDLE:-}" ] && _ca="$UNBOUND_CA_BUNDLE"
    [ -s "$_ca" ] && printf '%s' "$_ca"
}

# download_source ID URL: fetch + parse into the cache. Keeps the previous
# copy on any failure.
download_source() {
    _id="$1"; _url="$2"; _tmp="$RUN/dl.$_id"
    _ca="$(ca_bundle)" || { meta_write "$_id" "updated=$(meta_get "$_id" updated)" \
        "status=error" "message=no CA certificates found" "count=$(meta_get "$_id" count)"; return 1; }
    if _err="$("$BIN/curl" --fail --silent --show-error --location \
            --proto '=https' --proto-redir '=https' --cacert "$_ca" \
            --connect-timeout 20 --max-time 300 --retry 2 --retry-delay 3 \
            --max-filesize 104857600 --user-agent "unbound-dns-module" \
            -o "$_tmp" "$_url" 2>&1)" && lists_parse "$_tmp" "$CACHE/$_id.parsed.new"; then
        _count="$(grep -c '^B ' "$CACHE/$_id.parsed.new")"
        mv -f "$CACHE/$_id.parsed.new" "$CACHE/$_id.parsed"
        meta_write "$_id" "updated=$(now)" "status=ok" "message=" "count=$_count"
        log "lists: updated $_url ($_count domains)"
        _rc=0
    else
        rm -f "$CACHE/$_id.parsed.new"
        _err="$(printf '%s' "$_err" | tail -n 1 | tr -d '\000-\037' | cut -c1-160)"
        meta_write "$_id" "updated=$(meta_get "$_id" updated)" "status=error" \
            "message=${_err:-download failed}" "count=$(meta_get "$_id" count)"
        log "lists: failed $_url: $_err"
        _rc=1
    fi
    rm -f "$_tmp"
    return $_rc
}

# --- rebuilding blocklist.conf ------------------------------------------------

# Tagged lines from every enabled source, local file and the allowlist.
_all_entries() {
    [ -f "$SOURCES" ] && while IFS="$TAB" read -r _id _en _name _url; do
        [ "$_en" = 1 ] && [ -f "$CACHE/$_id.parsed" ] && cat "$CACHE/$_id.parsed"
    done < "$SOURCES"
    for _f in "$LOCAL_LISTS"/*; do
        [ -f "$_f" ] || continue
        lists_parse "$_f" "$RUN/local.parsed" && cat "$RUN/local.parsed"
    done
    rm -f "$RUN/local.parsed"
    [ -f "$ALLOW" ] && sed 's/^/A /' "$ALLOW"
    [ -f "$OWN_BLOCK" ] && sed 's/^/U /' "$OWN_BLOCK"
}

block_type() {
    if [ "$(setting_get BLOCK_ANSWER nxdomain)" = null ]; then echo always_null; else echo always_nxdomain; fi
}

# lists_rebuild [noreload]: regenerate blocklist.conf and reload Unbound
# (cache kept). "noreload" when the caller restarts Unbound anyway.
# shellcheck disable=SC2120  # ctl.sh passes "noreload"
lists_rebuild() {
    _new="$BLOCK_CONF.new"
    _all_entries | lists_merge "$_new" "$RUN/count.new" "$(block_type)" || { rm -f "$_new"; return 1; }
    # Belt and braces: every line must be one we generate.
    if grep -Ev '^(server:|local-zone: "[a-z0-9_.-]+\." (always_nxdomain|always_null|transparent))$' "$_new" | grep -q .; then
        log "lists: generated config failed validation; keeping the old one"
        rm -f "$_new"; return 1
    fi
    chmod 0644 "$_new"
    mv -f "$_new" "$BLOCK_CONF"
    mv -f "$RUN/count.new" "$BLOCK_COUNT"
    log "lists: blocklist rebuilt ($(cat "$BLOCK_COUNT") zones)"
    if [ "${1:-}" != noreload ] && unbound_running; then
        stats_bank                      # a reload zeroes Unbound's counters
        ubctl reload_keep_cache >/dev/null 2>&1 || ubctl reload >/dev/null 2>&1 \
            || { log "lists: reload failed"; return 1; }
    fi
    return 0
}

# lists_update [force]: download due (or all, with force) enabled sources,
# then rebuild. Returns non-zero if any download failed.
lists_update() {
    _force="${1:-0}"
    lock update || { echo "an update is already running" >&2; return 2; }
    _hours="$(setting_get REFRESH_HOURS 24)"
    _failed=0
    if [ -f "$SOURCES" ]; then
        # Read the list up front: download_source must not read our stdin.
        _rows="$(cat "$SOURCES")"
        _oldifs="$IFS"; IFS="$NL"
        for _row in $_rows; do
            IFS="$TAB" read -r _id _en _name _url <<EOR
$_row
EOR
            IFS="$_oldifs"
            [ "$_en" = 1 ] || continue
            _upd="$(meta_get "$_id" updated)"
            if [ "$_force" != 1 ] && [ -n "$_upd" ] && [ -f "$CACHE/$_id.parsed" ] \
                && [ $(( $(now) - _upd )) -lt $(( _hours * 3600 )) ]; then
                continue
            fi
            download_source "$_id" "$_url" || _failed=1
        done
    fi
    lists_rebuild || _failed=1
    setting_set LAST_UPDATE "$(now)"
    setting_set LAST_UPDATE_OK "$([ $_failed = 0 ] && echo 1 || echo 0)"
    unlock update
    return $_failed
}
