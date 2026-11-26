# Normalise a blocklist in any common format into tagged domain lines:
#   B <domain>   block <domain> and everything under it
#   A <domain>   allow <domain> and everything under it (list exceptions)
#
# Understood formats: hosts files, plain or "*."-wildcard domain lists,
# adblock-style "||domain^" / "@@||domain^", dnsmasq "address=/d/..." and
# "local=/d/", and Unbound "local-zone:" lines. Anything else is skipped.
#
# Run with LC_ALL=C (byte semantics) and -v bom="<UTF-8 BOM bytes>".

function valid(d,    n, i, lab, l) {
    if (length(d) < 3 || length(d) > 253) return 0
    if (d !~ /^[a-z0-9_.-]+$/) return 0
    if (index(d, ".") == 0) return 0
    if (d ~ /^[0-9.]+$/) return 0            # an IPv4 address, not a name
    n = split(d, lab, ".")
    for (i = 1; i <= n; i++) {
        l = lab[i]
        if (length(l) < 1 || length(l) > 63) return 0
        if (l ~ /^-/ || l ~ /-$/) return 0
    }
    return 1
}

function emit(tag, d) {
    d = tolower(d)
    sub(/\.$/, "", d)
    if (d in skip) return
    if (valid(d)) print tag " " d
}

# "example.com^", "example.com^$important", "example.com^|", "example.com"
function abp_domain(s,    p, d, mods) {
    p = index(s, "^")
    if (p == 0) { d = s; mods = "" }
    else { d = substr(s, 1, p - 1); mods = substr(s, p + 1) }
    sub(/^\|/, "", mods)
    if (mods != "" && mods != "$important") return ""
    if (d ~ /[\/*?:|=]/) return ""
    return d
}

BEGIN {
    n = split("localhost localhost.localdomain local broadcasthost " \
              "ip6-localhost ip6-loopback ip6-localnet ip6-mcastprefix " \
              "ip6-allnodes ip6-allrouters ip6-allhosts", s, " ")
    for (i = 1; i <= n; i++) skip[s[i]] = 1
}

{
    line = $0
    if (NR == 1 && bom != "" && substr(line, 1, length(bom)) == bom)
        line = substr(line, length(bom) + 1)
    sub(/\r$/, "", line)
    sub(/^[ \t]+/, "", line)

    if (line == "" || line ~ /^[#!\[]/) next

    if (substr(line, 1, 4) == "@@||") {
        d = abp_domain(substr(line, 5)); if (d != "") emit("A", d); next
    }
    if (substr(line, 1, 2) == "||") {
        d = abp_domain(substr(line, 3)); if (d != "") emit("B", d); next
    }
    if (line ~ /^(address|local)=\//) {
        n = split(line, p, "/")
        for (i = 2; i < n; i++) emit("B", p[i])
        next
    }
    if (line ~ /^local-zone:/) {
        if (line ~ /transparent|nodefault|inform/) next
        if (match(line, /"[^"]+"/)) emit("B", substr(line, RSTART + 1, RLENGTH - 2))
        next
    }
    if (line ~ /^[a-z-]+:/ || line ~ /^[a-z-]+=/) next   # other config syntax

    sub(/#.*$/, "", line)
    sub(/[ \t]+$/, "", line)
    n = split(line, f, /[ \t]+/)
    if (n == 0) next

    if (f[1] ~ /^[0-9.]+$/ || index(f[1], ":") > 0) {        # hosts file
        for (i = 2; i <= n; i++) emit("B", f[i])
        next
    }
    if (n == 1) {
        d = f[1]
        sub(/^\*\./, "", d)
        sub(/^\./, "", d)
        emit("B", d)
    }
}
