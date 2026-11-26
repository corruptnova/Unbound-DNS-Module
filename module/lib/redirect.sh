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

# _chains_add IPT: build both chains for one family. Fails if NAT is missing.
_chains_add() {
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

    # Blocking 853 is a hardening extra: never fail the redirect over it.
    if _ipt "$_i" -w -N "$DOT_CHAIN" || _ipt "$_i" -w -F "$DOT_CHAIN"; then
        for _u in $(exempt_uids | awk '!seen[$0]++'); do
            _ipt "$_i" -w -A "$DOT_CHAIN" -m owner --uid-owner "$_u" -j RETURN
        done
        _ipt "$_i" -w -A "$DOT_CHAIN" -p tcp --dport 853 -j REJECT --reject-with tcp-reset
        _ipt "$_i" -w -A "$DOT_CHAIN" -p udp --dport 853 -j REJECT
        _ipt "$_i" -w -C OUTPUT -j "$DOT_CHAIN" || _ipt "$_i" -w -I OUTPUT -j "$DOT_CHAIN"
    fi
    # The jump into the redirect goes in last: once it exists (what
    # redirect_active checks), every other rule is already in place.
    _ipt "$_i" -w -t nat -C OUTPUT -j "$NAT_CHAIN" || _ipt "$_i" -w -t nat -I OUTPUT -j "$NAT_CHAIN" || return 1
    return 0
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
    rm -f "$RUN/redirect.v6" "$RUN/nat64.iptables" "$RUN/nat64.ip6tables"
}

redirect_active() { _ipt iptables -w -t nat -C OUTPUT -j "$NAT_CHAIN"; }
