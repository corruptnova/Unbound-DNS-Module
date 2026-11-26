#!/bin/sh
# Blocklist parser (blocklist.awk) and merger (merge.awk).
. "${TESTS_DIR:-$(dirname "$0")}/lib.sh"
. "$LIB_DIR/lists.sh"

parse() { printf '%b' "$1" > "$TMP/in"; lists_parse "$TMP/in" "$TMP/out"; cat "$TMP/out"; }

# --- hosts files -----------------------------------------------------------
out="$(parse '# comment\n127.0.0.1 localhost\n::1 localhost ip6-localhost\n0.0.0.0 ads.example.com\n127.0.0.1\ttrack.example.net  # trailing\n:: v6.example.org\n0.0.0.0 a.example.com b.example.com\n255.255.255.255 broadcasthost\n0.0.0.0 0.0.0.0\n')"
assert_eq "hosts" "B ads.example.com
B track.example.net
B v6.example.org
B a.example.com
B b.example.com" "$out"

# --- plain and wildcard domain lists ------------------------------------
out="$(parse 'plain.example.com\n*.wild.example.com\n.dot.example.com\nUPPER.Example.COM\ntrailing.example.com.\n')"
assert_eq "domains" "B plain.example.com
B wild.example.com
B dot.example.com
B upper.example.com
B trailing.example.com" "$out"

# --- adblock syntax -------------------------------------------------------
out="$(parse '[Adblock Plus 2.0]\n! Title: test\n||abp.example.com^\n||imp.example.com^$important\n@@||allowed.example.com^\n||mod.example.com^$third-party\n||path.example.com/ads^\n||wild*.example.com^\n/regex[0-9]+/\n|https://url.example.com/\n||anchor.example.com^|\n')"
assert_eq "adblock" "B abp.example.com
B imp.example.com
A allowed.example.com
B anchor.example.com" "$out"

# --- dnsmasq and unbound syntax -------------------------------------------
out="$(parse 'address=/dm.example.com/0.0.0.0\naddress=/dm1.example.com/dm2.example.com/#\nlocal=/loc.example.com/\nserver=/fwd.example.com/1.1.1.1\nlocal-zone: "ub.example.com" always_nxdomain\nlocal-zone: "ok.example.com." transparent\nlocal-data: "x.example.com A 1.2.3.4"\nserver:\n')"
assert_eq "dnsmasq+unbound" "B dm.example.com
B dm1.example.com
B dm2.example.com
B loc.example.com
B ub.example.com" "$out"

# --- line endings, BOM, junk -----------------------------------------------
out="$(parse '\357\273\277bom.example.com\r\ncrlf.example.com\r\n   indented.example.com\n-bad.example.com\nbad-.example.com\nbad..example.com\nbad_ok.example.com\nsingle\n1.2.3.4\nhas space.com extra\nbad!.example.com\nxn--bcher-kva.example\n')"
assert_eq "junk" "B bom.example.com
B crlf.example.com
B indented.example.com
B bad_ok.example.com
B xn--bcher-kva.example" "$out"

long="$(printf 'a%.0s' $(seq 1 64)).example.com"
out="$(parse "$long\\n")"
assert_eq "label > 63 rejected" "" "$out"

# --- merging ---------------------------------------------------------------
merge() { printf '%b' "$1" | lists_merge "$TMP/conf" "$TMP/count"; cat "$TMP/conf"; }

out="$(merge 'B example.com\nB ads.example.com\nB deep.ads.example.com\nB example-foo.com\nB other.net\nB example.com\n')"
assert_eq "merge prunes covered subdomains" 'server:
local-zone: "example.com." always_nxdomain
local-zone: "example-foo.com." always_nxdomain
local-zone: "other.net." always_nxdomain' "$out"
assert_eq "merge count" "3" "$(cat "$TMP/count")"

# Siblings that share a prefix must not be treated as children.
out="$(merge 'B ads.com\nB ads-cdn.com\nB x.ads-cdn.com\nB adsx.com\n')"
assert_eq "prefix siblings" 'server:
local-zone: "ads.com." always_nxdomain
local-zone: "ads-cdn.com." always_nxdomain
local-zone: "adsx.com." always_nxdomain' "$out"

# allow under a block -> transparent; block under an allow -> dropped;
# exact allow beats exact block.
out="$(merge 'B tracker.com\nA ok.tracker.com\nB cdn.ok.tracker.com\nA safe.org\nB ads.safe.org\nB safe.org\nB x.test\nA x.test\n')"
assert_eq "allow wins" 'server:
local-zone: "tracker.com." always_nxdomain
local-zone: "ok.tracker.com." transparent' "$out"
assert_eq "allow count" "1" "$(cat "$TMP/count")"

# Own blocks (U) beat list exceptions and the allowlist when more specific;
# an exact tie goes to the allowlist; covered own blocks are dropped.
out="$(merge 'A example.com\nU ads.example.com\nU example.com\nB tracker.net\nU sub.tracker.net\nU own.org\nA x.own.org\n')"
assert_eq "own block precedence" 'server:
local-zone: "ads.example.com." always_nxdomain
local-zone: "tracker.net." always_nxdomain
local-zone: "own.org." always_nxdomain
local-zone: "x.own.org." transparent' "$out"
assert_eq "own block count" "3" "$(cat "$TMP/count")"

# Blocked names can answer 0.0.0.0 / :: instead of NXDOMAIN.
printf 'B a.example\nU b.example\n' | lists_merge "$TMP/conf" "$TMP/count" always_null
assert_eq "always_null block type" 'server:
local-zone: "a.example." always_null
local-zone: "b.example." always_null' "$(cat "$TMP/conf")"

out="$(merge '')"
assert_eq "empty merge" "server:" "$out"
assert_eq "empty count" "0" "$(cat "$TMP/count")"

done_testing
