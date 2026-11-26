# Turn sorted "<reversed-name> <tag>" lines into Unbound local-zone config.
#
# Input names are reversed and joined with "!" (example.com -> com!example)
# and sorted with LC_ALL=C. "!" sorts below every character allowed in a
# name, so a name's subtree directly follows it.
#
# Tags: A = allow (allowlist, list exceptions), B = block from a downloaded
# list, U = the user's own block. Sorted A < B < U, so on an exact name tie
# the allow comes first.
#
# Rules:
#   B or U under a kept B/U -> dropped (already covered by the parent zone)
#   B under an A            -> dropped (allow covers the whole subtree)
#   U under an A            -> blocked: the user's own, more specific entry
#                              wins, except on an exact tie with the allow
#   A under a kept B/U      -> "transparent" zone, which overrides the parent
#   any other B or U        -> block zone (blocktype, default always_nxdomain)
#
# Writes config to stdout and the number of blocking zones to countfile.

function fwd(r,    n, l, i, s) {
    n = split(r, l, "!")
    s = l[n]
    for (i = n - 1; i >= 1; i--) s = s "." l[i]
    return s
}

function block(name, tag) {
    print "local-zone: \"" fwd(name) ".\" " blocktype
    blocked++
    st[++sp] = name; tg[sp] = tag
}

BEGIN {
    sp = 0; blocked = 0
    if (blocktype == "") blocktype = "always_nxdomain"
    print "server:"
}

{
    name = $1; tag = $2
    while (sp > 0 && name != st[sp] && index(name, st[sp] "!") != 1) sp--
    parent = (sp > 0) ? tg[sp] : ""

    if (tag == "A") {
        if (parent == "B" || parent == "U") print "local-zone: \"" fwd(name) ".\" transparent"
        st[++sp] = name; tg[sp] = "A"
    } else if (parent == "") {
        block(name, tag)
    } else if (tag == "U" && parent == "A" && st[sp] != name) {
        block(name, tag)
    }
}

END { if (countfile != "") print blocked > countfile }
