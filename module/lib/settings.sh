# Unbound settings chosen in the WebUI or the installer: defaults,
# validation and rendering into options.conf. Sourced; needs common.sh.
# shellcheck shell=sh

FORWARDERS="$DATA/forwarders.list"     # custom DoT servers, "addr[@port]#tls-name"
OPTIONS_CONF="$DATA/options.conf"
CA_IN_CHROOT="$DATA/ca.pem"

SETTING_KEYS="RESOLVER CACHE_SIZE CACHE_MIN_TTL CACHE_MAX_TTL PREFETCH SERVE_EXPIRED THREADS DNSSEC DNSSEC_PERMISSIVE QNAME_MIN REBIND_PROTECT UPSTREAM_IPV6 BLOCK_ANSWER LOG_LEVEL"

setting_default() {
    case "$1" in
        RESOLVER) echo recursive ;;
        CACHE_SIZE) echo medium ;;
        CACHE_MIN_TTL) echo 0 ;;
        CACHE_MAX_TTL) echo 86400 ;;
        PREFETCH|SERVE_EXPIRED|DNSSEC|QNAME_MIN|UPSTREAM_IPV6) echo 1 ;;
        DNSSEC_PERMISSIVE|REBIND_PROTECT) echo 0 ;;
        THREADS) echo 1 ;;
        BLOCK_ANSWER) echo nxdomain ;;
        LOG_LEVEL) echo 1 ;;
    esac
}

# opt KEY: the stored value, or the default.
opt() { setting_get "$1" "$(setting_default "$1")"; }

# num_in VALUE MIN MAX
num_in() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 7 ] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

# setting_valid KEY VALUE
setting_valid() {
    case "$1" in
        RESOLVER) case "$2" in recursive|cloudflare|quad9|controld|custom) return 0 ;; esac ;;
        CACHE_SIZE) case "$2" in small|medium|large) return 0 ;; esac ;;
        CACHE_MIN_TTL) num_in "$2" 0 3600 && return 0 ;;
        CACHE_MAX_TTL) num_in "$2" 60 604800 && return 0 ;;
        PREFETCH|SERVE_EXPIRED|DNSSEC|DNSSEC_PERMISSIVE|QNAME_MIN|REBIND_PROTECT|UPSTREAM_IPV6)
            case "$2" in 0|1) return 0 ;; esac ;;
        THREADS) num_in "$2" 1 4 && return 0 ;;
        BLOCK_ANSWER) case "$2" in nxdomain|null) return 0 ;; esac ;;
        LOG_LEVEL) num_in "$2" 0 3 && return 0 ;;
    esac
    return 1
}

is_setting_key() { case " $SETTING_KEYS " in *" $1 "*) return 0 ;; esac; return 1; }

# valid_forwarder "addr[@port]#tls-name": IPv4 or IPv6 address, optional
# port, and the TLS name the server's certificate must carry.
valid_forwarder() {
    no_newline "$1" || return 1
    printf '%s\n' "$1" | grep -Eq \
        '^([0-9]{1,3}(\.[0-9]{1,3}){3}|[0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{0,4}){2,7})(@[0-9]{1,5})?#[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$'
}

# Encrypted (DNS-over-TLS) resolvers offered in the installer and WebUI.
# Mullvad's public DNS shut down on 2026-11-02, so it is not offered.
preset_forwarders() {
    case "$1" in
        cloudflare)
            for _a in 1.1.1.1 1.0.0.1 2606:4700:4700::1111 2606:4700:4700::1001; do
                echo "$_a@853#cloudflare-dns.com"; done ;;
        quad9)
            for _a in 9.9.9.9 149.112.112.112 2620:fe::fe 2620:fe::9; do
                echo "$_a@853#dns.quad9.net"; done ;;
        controld)
            for _a in 76.76.2.0 76.76.10.0 2606:1a40::0 2606:1a40:1::0; do
                echo "$_a@853#p0.freedns.controld.com"; done ;;
        custom)
            [ -f "$FORWARDERS" ] && grep -v '^[[:space:]]*$' "$FORWARDERS" ;;
    esac
}

resolver_label() {
    case "$1" in
        recursive) echo "Recursive (on this phone)" ;;
        cloudflare) echo "Cloudflare (encrypted)" ;;
        quad9) echo "Quad9 (encrypted)" ;;
        controld) echo "ControlD free (encrypted)" ;;
        custom) echo "Custom servers (encrypted)" ;;
    esac
}

_yn() { if [ "$1" = 1 ]; then echo yes; else echo no; fi; }

# Android's system CA store, copied inside the chroot for DNS-over-TLS.
install_ca_bundle() {
    _ca="$(ca_bundle)" || return 0
    cp -f "$_ca" "$CA_IN_CHROOT.tmp" 2>/dev/null && mv -f "$CA_IN_CHROOT.tmp" "$CA_IN_CHROOT"
    chmod 0644 "$CA_IN_CHROOT" 2>/dev/null
}

write_options_conf() {
    _threads="$(opt THREADS)"
    _slabs=1
    [ "$_threads" -ge 2 ] && _slabs=2
    [ "$_threads" -ge 3 ] && _slabs=4
    case "$(opt CACHE_SIZE)" in
        small) _msg=4m; _rr=8m; _key=2m ;;
        large) _msg=32m; _rr=64m; _key=8m ;;
        *) _msg=8m; _rr=16m; _key=4m ;;
    esac
    _resolver="$(opt RESOLVER)"
    {
        echo "# Generated from the WebUI settings by ctl.sh; do not edit."
        echo "# Your own settings belong in custom.conf, which is read after this."
        echo "server:"
        echo "    num-threads: $_threads"
        for _s in msg rrset infra key; do echo "    $_s-cache-slabs: $_slabs"; done
        echo "    msg-cache-size: $_msg"
        echo "    rrset-cache-size: $_rr"
        echo "    key-cache-size: $_key"
        echo "    cache-min-ttl: $(opt CACHE_MIN_TTL)"
        echo "    cache-max-ttl: $(opt CACHE_MAX_TTL)"
        echo "    prefetch: $(_yn "$(opt PREFETCH)")"
        echo "    prefetch-key: $(_yn "$(opt PREFETCH)")"
        echo "    serve-expired: $(_yn "$(opt SERVE_EXPIRED)")"
        echo "    qname-minimisation: $(_yn "$(opt QNAME_MIN)")"
        echo "    verbosity: $(opt LOG_LEVEL)"
        if [ "$(opt DNSSEC)" = 1 ]; then
            echo '    module-config: "validator iterator"'
            echo "    val-permissive-mode: $(_yn "$(opt DNSSEC_PERMISSIVE)")"
        else
            echo '    module-config: "iterator"'
        fi
        if [ "$(opt REBIND_PROTECT)" = 1 ]; then
            for _n in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 \
                    fd00::/8 fe80::/10 ::ffff:0:0/96; do
                echo "    private-address: $_n"
            done
        fi
        if [ -s "$CA_IN_CHROOT" ]; then
            echo "    tls-cert-bundle: \"$CA_IN_CHROOT\""
        fi
        if [ "$_resolver" != recursive ]; then
            echo "forward-zone:"
            echo '    name: "."'
            echo "    forward-tls-upstream: yes"
            preset_forwarders "$_resolver" | while read -r _f; do
                valid_forwarder "$_f" && echo "    forward-addr: $_f"
            done
        fi
    } > "$OPTIONS_CONF.tmp" && mv -f "$OPTIONS_CONF.tmp" "$OPTIONS_CONF"
    chown 0:"$UB_UID" "$OPTIONS_CONF" 2>/dev/null
    chmod 0640 "$OPTIONS_CONF"
}

# anchor_json: what root.key says about the DNSSEC root keys.
anchor_json() {
    _rk="$(ub_read root.key 2>/dev/null)"
    printf '{"keys":['
    # Matches both the shipped file (". IN DNSKEY 257 ...", spaces) and the
    # file Unbound rewrites while tracking keys (tab-separated fields plus
    # ";;state=" comments).
    printf '%s\n' "$_rk" | LC_ALL=C awk '
        /^;/ { next }
        /DNSKEY[ \t]+257[ \t]/ || /[ \t]DS[ \t]/ {
            id = ""; state = ""
            if (match($0, /id = [0-9]+/)) id = substr($0, RSTART + 5, RLENGTH - 5)
            else if (match($0, /keytag [0-9]+/)) id = substr($0, RSTART + 7, RLENGTH - 7)
            if (match($0, /\[ *[A-Z]+ *\]/)) { state = substr($0, RSTART + 1, RLENGTH - 2); gsub(/ /, "", state) }
            if (id == "") next
            printf "%s{\"id\":%s,\"state\":\"%s\"}", (n++ ? "," : ""), id, state
        }'
    _ls="$(printf '%s\n' "$_rk" | sed -n 's/^;;last_success: \([0-9]*\).*/\1/p' | head -n 1)"
    _mt="$(stat -c %Y "$VAR/root.key" 2>/dev/null)"
    printf '],"last_success":%s,"modified":%s}' "$(json_num "$_ls")" "$(json_num "$_mt")"
}

settings_json() {
    printf '{"settings":{'
    _first=1
    for _k in $SETTING_KEYS; do
        [ $_first = 1 ] || printf ','
        _first=0
        printf '"%s":"%s"' "$_k" "$(json_esc "$(opt "$_k")")"
    done
    printf '},"defaults":{'
    _first=1
    for _k in $SETTING_KEYS; do
        [ $_first = 1 ] || printf ','
        _first=0
        printf '"%s":"%s"' "$_k" "$(json_esc "$(setting_default "$_k")")"
    done
    printf '},"forwarders":'
    json_lines "$FORWARDERS"
    printf ',"resolver_label":"%s","anchor":' "$(json_esc "$(resolver_label "$(opt RESOLVER)")")"
    anchor_json
    printf '}\n'
}
