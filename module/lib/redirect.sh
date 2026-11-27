# Send every DNS query on the phone to the local Unbound.
# shellcheck shell=sh
#
# nat/OUTPUT -> UNBOUND_DNS: RETURN for exempt uids and NAT64 discovery,
# REDIRECT udp/tcp 53 to UB_PORT. filter/OUTPUT -> UNBOUND_DOT: REJECT 853 (DNS-over-TLS/QUIC) so
# nothing quietly bypasses the resolver. IPv6 is best effort: kernels without
# IPv6 NAT keep their IPv6 DNS untouched rather than losing DNS altogether.

NAT_CHAIN=UNBOUND_DNS
DOT_CHAIN=UNBOUND_DOT
AID_NETWORK_STACK=1073
CAPTIVE_PORTAL_PKGS="com.android.captiveportallogin com.google.android.captiveportallogin"

# RFC 7050 NAT64 prefix discovery: Android asks the network's resolver for
# the AAAA of ipv4only.arpa and only starts 464XLAT (clat) once that DNS64
# resolver answers. On IPv6-only networks (most US carriers) Unbound cannot
# give that answer, so IPv4-only services (GitHub, ...) become unreachable.
# Letting just this one name through reveals nothing about what is browsed.
# Matched in the first (and only) packet of a UDP query, in wire format.
NAT64_QNAME='|08|ipv4only|04|arpa|00|'

# Unbound itself, Android's network-validation stack and the captive portal
# login app (so "Sign in to network" keeps working).
exempt_uids() {
    echo "$UB_UID"
    echo "$AID_NETWORK_STACK"
    for _p in $CAPTIVE_PORTAL_PKGS; do
        [ -d "$APPDATA/$_p" ] && stat -c %u "$APPDATA/$_p" 2>/dev/null
    done
}

_ipt() { "$@" 2>/dev/null; }

# Only our own chains (UNBOUND_DNS, UNBOUND_DOT) and the two jumps into them
# are ever created, changed or removed. They never ACCEPT anything: a packet
# is redirected (port 53), rejected (port 853) or handed on to the next rule,
# so another firewall's rules keep working as before.

# _nat_chain IPT: (re)build our nat chain. Fails if the kernel has no NAT.
_nat_chain() {
    _i="$1"
    _ipt "$_i" -w -t nat -N "$NAT_CHAIN" || _ipt "$_i" -w -t nat -F "$NAT_CHAIN" || return 1
    for _u in $(exempt_uids | awk '!seen[$0]++'); do
        _ipt "$_i" -w -t nat -A "$NAT_CHAIN" -m owner --uid-owner "$_u" -j RETURN || return 1
    done
    # Needs the kernel's string match; without it, keep redirecting anyway.
    if _ipt "$_i" -w -t nat -A "$NAT_CHAIN" -p udp --dport 53 -m string --algo bm --icase \
            --hex-string "$NAT64_QNAME" -j RETURN; then
        echo ok > "$RUN/nat64.$_i"
    else
        echo unsupported > "$RUN/nat64.$_i"
        log "redirect: $_i has no string match; NAT64 discovery (IPv6-only networks) goes to Unbound"
    fi
    _ipt "$_i" -w -t nat -A "$NAT_CHAIN" -p udp --dport 53 -j REDIRECT --to-ports "$UB_PORT" || return 1
    _ipt "$_i" -w -t nat -A "$NAT_CHAIN" -p tcp --dport 53 -j REDIRECT --to-ports "$UB_PORT" || return 1
}

# _nat_jump IPT: the jump from nat OUTPUT into our chain.
_nat_jump() {
    _ipt "$1" -w -t nat -C OUTPUT -j "$NAT_CHAIN" || _ipt "$1" -w -t nat -I OUTPUT -j "$NAT_CHAIN"
}

# _dot_add IPT: (re)build the DoT block and its jump; records dot.IPT when
# it is in place. Blocking 853 is a hardening extra: it never fails the
# redirect.
_dot_add() {
    _i="$1"
    rm -f "$RUN/dot.$_i"
    if _ipt "$_i" -w -N "$DOT_CHAIN" || _ipt "$_i" -w -F "$DOT_CHAIN"; then
        for _u in $(exempt_uids | awk '!seen[$0]++'); do
            _ipt "$_i" -w -A "$DOT_CHAIN" -m owner --uid-owner "$_u" -j RETURN
        done
        _ipt "$_i" -w -A "$DOT_CHAIN" -p tcp --dport 853 -j REJECT --reject-with tcp-reset
        _ipt "$_i" -w -A "$DOT_CHAIN" -p udp --dport 853 -j REJECT
        if _ipt "$_i" -w -C OUTPUT -j "$DOT_CHAIN" || _ipt "$_i" -w -I OUTPUT -j "$DOT_CHAIN"; then
            echo ok > "$RUN/dot.$_i"
        fi
    fi
    return 0
}

# _chains_add IPT: everything for one family. The jump into the redirect
# goes in last: once it exists (what redirect_active checks), every other
# rule is already in place.
_chains_add() {
    _nat_chain "$1" || return 1
    _dot_add "$1"
    _nat_jump "$1"
}

_chains_del() {
    _i="$1"
    while _ipt "$_i" -w -t nat -C OUTPUT -j "$NAT_CHAIN"; do
        _ipt "$_i" -w -t nat -D OUTPUT -j "$NAT_CHAIN" || break
    done
    _ipt "$_i" -w -t nat -F "$NAT_CHAIN"; _ipt "$_i" -w -t nat -X "$NAT_CHAIN"
    while _ipt "$_i" -w -C OUTPUT -j "$DOT_CHAIN"; do
        _ipt "$_i" -w -D OUTPUT -j "$DOT_CHAIN" || break
    done
    _ipt "$_i" -w -F "$DOT_CHAIN"; _ipt "$_i" -w -X "$DOT_CHAIN"
    return 0
}

# redirect_apply: IPv4 must succeed; IPv6 is recorded as ok/unsupported.
# IPv6 goes first so its status is known by the time the IPv4 jump (which
# redirect_active looks for) appears.
redirect_apply() {
    if _chains_add ip6tables; then
        echo ok > "$RUN/redirect.v6"
    else
        _chains_del ip6tables
        echo unsupported > "$RUN/redirect.v6"
        log "redirect: IPv6 NAT unavailable on this kernel; IPv6 DNS is not redirected"
    fi
    if ! _chains_add iptables; then
        _chains_del iptables
        _chains_del ip6tables
        rm -f "$RUN/redirect.v6"
        log "redirect: failed to install IPv4 rules"
        return 1
    fi
    log "redirect: on"
}

redirect_remove() {
    _chains_del iptables
    _chains_del ip6tables
    rm -f "$RUN/redirect.v6" "$RUN/nat64.iptables" "$RUN/nat64.ip6tables" \
        "$RUN/dot.iptables" "$RUN/dot.ip6tables"
}

# _has_jump IPT TABLE CHAIN: OUTPUT in TABLE still jumps to CHAIN. Reads
# the rules with IPT-save, which (unlike "iptables -C") does not take the
# xtables lock, so looking never makes another app's iptables command wait
# or fail. Returns 0 yes, 1 no, 2 could not tell.
_has_jump() {
    _hj="$("$1-save" -t "$2" 2>/dev/null)"
    _hs=$?
    if [ "$_hs" = 127 ]; then                 # no IPT-save on this system
        _ipt "$1" -w -t "$2" -C OUTPUT -j "$3"
        return
    fi
    { [ "$_hs" = 0 ] && [ -n "$_hj" ]; } || return 2
    case "$NL$_hj$NL" in *"$NL-A OUTPUT -j $3$NL"*) return 0 ;; esac
    return 1
}

# _installed IPT PART: we put PART (v6, dot) in place for IPT.
_installed() {
    _inst=""
    case "$2" in
        v6) read -r _inst < "$RUN/redirect.v6" 2>/dev/null ;;
        dot) read -r _inst < "$RUN/dot.$1" 2>/dev/null ;;
    esac
    [ "$_inst" = ok ]
}

# redirect_active: the IPv4 jump into the redirect is there.
redirect_active() {
    _has_jump iptables nat "$NAT_CHAIN"
    case $? in 0) return 0 ;; 1) return 1 ;; esac
    _ipt iptables -w -t nat -C OUTPUT -j "$NAT_CHAIN"
}

# redirect_missing [all]: one of our jumps is certainly gone. Plain: only
# the IPv4 DNS jump (small nat table). "all": also IPv6 and the DoT blocks
# (the filter table is large). A read that fails counts as "not gone".
redirect_missing() {
    _has_jump iptables nat "$NAT_CHAIN"; [ $? = 1 ] && return 0
    [ "${1:-}" = all ] || return 1
    if _installed iptables dot; then
        _has_jump iptables filter "$DOT_CHAIN"; [ $? = 1 ] && return 0
    fi
    _installed ip6tables v6 || return 1
    _has_jump ip6tables nat "$NAT_CHAIN"; [ $? = 1 ] && return 0
    if _installed ip6tables dot; then
        _has_jump ip6tables filter "$DOT_CHAIN"; [ $? = 1 ] && return 0
    fi
    return 1
}

# redirect_repair: put back whichever of our jumps are gone, rebuilding only
# our own chain behind each; the parts still in place are left alone.
redirect_repair() {
    _fixed=""
    for _i in iptables ip6tables; do
        [ "$_i" = iptables ] || _installed ip6tables v6 || continue
        if _installed "$_i" dot && ! _ipt "$_i" -w -C OUTPUT -j "$DOT_CHAIN"; then
            _dot_add "$_i"
            _fixed="$_fixed $_i/$DOT_CHAIN"
        fi
        _ipt "$_i" -w -t nat -C OUTPUT -j "$NAT_CHAIN" && continue
        if _nat_chain "$_i" && _nat_jump "$_i"; then
            _fixed="$_fixed $_i/$NAT_CHAIN"
        elif [ "$_i" = iptables ]; then
            log "redirect: could not put the IPv4 rules back"
            return 1
        else
            _chains_del ip6tables
            echo unsupported > "$RUN/redirect.v6"
            log "redirect: could not put the IPv6 rules back; IPv6 DNS is not redirected"
        fi
    done
    [ -z "$_fixed" ] || log "redirect: put back our rules that were removed:$_fixed"
    return 0
}
