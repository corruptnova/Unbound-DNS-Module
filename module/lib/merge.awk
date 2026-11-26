# Turn sorted "<reversed-name> <tag>" lines into Unbound local-zone config.
#
# Input names are reversed and joined with "!" (example.com -> com!example)
# and sorted with LC_ALL=C. "!" sorts below every character allowed in a
# name, so a name's subtree directly follows it. Tags: A (allow) sorts
# before B (block), so an allow wins over a block of the same name.
#
# Rules:
#   B under a kept B     -> dropped (already covered by the parent zone)
#   B under an A         -> dropped (allow covers the whole subtree)
#   A under a kept B     -> "transparent" zone, which overrides the parent
#   everything else B    -> "always_nxdomain" zone
#
# Writes config to stdout and the number of blocking zones to countfile.

function fwd(r,    n, l, i, s) {
    n = split(r, l, "!")
    s = l[n]
    for (i = n - 1; i >= 1; i--) s = s "." l[i]
    return s
}

BEGIN { sp = 0; blocked = 0; print "server:" }

{
    name = $1; tag = $2
    while (sp > 0 && name != st[sp] && index(name, st[sp] "!") != 1) sp--
    parent = (sp > 0) ? tg[sp] : ""

    if (tag == "A") {
        if (parent == "B") print "local-zone: \"" fwd(name) ".\" transparent"
        st[++sp] = name; tg[sp] = "A"
    } else if (parent == "") {
        print "local-zone: \"" fwd(name) ".\" always_nxdomain"
        blocked++
        st[++sp] = name; tg[sp] = "B"
    }
}

END { if (countfile != "") print blocked > countfile }
