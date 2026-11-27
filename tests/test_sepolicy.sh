#!/bin/sh
# module/sepolicy.rule: the root manager skips a statement it cannot apply,
# without saying so, so check here what can be checked without a device:
# every class exists, every permission exists in each class of its statement,
# and sources and targets are single, named types: one type a device lacks
# (magisk on KernelSU, su on user builds) then only costs that one statement,
# and "self", which only the policy compiler knows, is not used.
. "${TESTS_DIR:-$(dirname "$0")}/lib.sh"

RULES="$REPO_DIR/module/sepolicy.rule"
check_rules() {
    awk -v table="$TESTS_DIR/selinux-classes.txt" '
        function items(s,    a, n, i, out) {
            gsub(/[{}]/, " ", s); n = split(s, a, " "); out = ""
            for (i = 1; i <= n; i++) out = out " " a[i]
            return out
        }
        BEGIN {
            while ((getline l < table) > 0) {
                if (l ~ /^#/ || l == "") continue
                n = split(l, a, " ")
                known[a[1]] = 1
                for (i = 2; i <= n; i++) perm[a[1], a[i]] = 1
            }
        }
        { sub(/#.*/, "") }
        $1 == "allow" || $1 == "dontaudit" || $1 == "auditallow" {
            line = $0; f = 0
            # Split into fields, keeping { ... } groups whole.
            while (match(line, /\{[^}]*\}|[^ \t]+/)) {
                fld[++f] = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
            }
            if (f != 5) { print NR ": needs 5 fields: " $0; bad++; next }
            if (fld[2] ~ /[{*]/ || fld[3] ~ /[{*]/) { print NR ": one source and one target per statement: " $0; bad++ }
            if (fld[2] == "self" || fld[3] == "self") { print NR ": self is not a type the root managers know: " $0; bad++ }
            nc = split(items(fld[4]), cls, " "); np = split(items(fld[5]), pm, " ")
            for (i = 1; i <= nc; i++) {
                if (!(cls[i] in known)) { print NR ": no class " cls[i]; bad++; continue }
                for (j = 1; j <= np; j++)
                    if (pm[j] != "*" && !((cls[i], pm[j]) in perm)) { print NR ": " cls[i] " has no " pm[j]; bad++ }
            }
        }
        END { exit bad > 0 }' "$1"
}

out="$(check_rules "$RULES" 2>&1)"
assert_eq "sepolicy.rule statements all apply" "" "$out"

# The check finds what it is for.
printf 'allow ksu unbound_dns { dir file } { getattr search }\n' > "$TMP/bad.rule"
assert_contains "permission missing from a class" "file has no search" "$(check_rules "$TMP/bad.rule")"
printf 'allow { ksu magisk } unbound_dns fd use\n' > "$TMP/bad.rule"
assert_contains "two sources in one statement" "one source and one target" "$(check_rules "$TMP/bad.rule")"
printf 'allow unbound_dns self fd use\n' > "$TMP/bad.rule"
assert_contains "self" "self is not a type" "$(check_rules "$TMP/bad.rule")"
printf 'allow ksu unbound_dns nosuchclass read\n' > "$TMP/bad.rule"
assert_contains "unknown class" "no class nosuchclass" "$(check_rules "$TMP/bad.rule")"

# Every type and attribute the module defines is declared before it is used.
declared="$(awk '$1 == "type" { print $2 }' "$RULES")"
for t in unbound_dns unbound_dns_exec unbound_dns_data_file; do
    assert_contains "type $t declared" "$t" "$declared"
done
assert_eq "the domain is permissive in the learning stage" "permissive unbound_dns" "$(grep '^permissive' "$RULES")"

done_testing
