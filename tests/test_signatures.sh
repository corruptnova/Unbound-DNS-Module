#!/bin/sh
# Release signature checks (scripts/lib.sh verify_signature), offline, with
# throwaway keys. Also: every pinned key in keys/ loads. Needs bash and gnupg.
. "${TESTS_DIR:-$(dirname "$0")}/lib.sh"

if ! command -v bash >/dev/null 2>&1 || ! command -v gpg >/dev/null 2>&1 || ! command -v gpgv >/dev/null 2>&1; then
    echo "test_signatures.sh: skipped (needs bash, gpg, gpgv)"
    exit 0
fi

G="$TMP/gnupg"; mkdir -m 700 "$G"
R="$TMP/root"; mkdir -p "$R/keys"
gpg_() { gpg --batch --quiet --homedir "$G" --passphrase '' --pinentry-mode loopback "$@"; }
gpg_ --quick-gen-key 'Release <release@example.org>' ed25519 sign never 2>/dev/null
gpg_ --quick-gen-key 'Someone Else <else@example.org>' ed25519 sign never 2>/dev/null
gpg_ --armor --export release@example.org > "$R/keys/proj.asc"

echo "release contents" > "$TMP/proj.tar.gz"
gpg_ --local-user release@example.org --armor --detach-sign -o "$TMP/good.asc" "$TMP/proj.tar.gz"
gpg_ --local-user else@example.org --armor --detach-sign -o "$TMP/other.asc" "$TMP/proj.tar.gz"
cp "$TMP/proj.tar.gz" "$TMP/tampered.tar.gz"; echo "extra" >> "$TMP/tampered.tar.gz"

# verify NAME FILE SIG: the module's check, with keys/ pointed at $R/keys.
verify() { bash -c '. "$1/scripts/lib.sh"; ROOT_DIR="$2"; verify_signature "$3" "$4" "$5"' _ "$REPO_DIR" "$R" "$@"; }
assert_ok "good signature accepted" verify proj "$TMP/proj.tar.gz" "$TMP/good.asc"
assert_fails "tampered file refused" verify proj "$TMP/tampered.tar.gz" "$TMP/good.asc"
assert_fails "signature by another key refused" verify proj "$TMP/proj.tar.gz" "$TMP/other.asc"
assert_fails "missing signature refused" verify proj "$TMP/proj.tar.gz" "$TMP/none.asc"
assert_fails "project without a pinned key refused" verify other "$TMP/proj.tar.gz" "$TMP/good.asc"

# The pinned keys parse and have the fingerprints listed in keys/README.md.
for k in unbound openssl expat curl; do
    fpr="$(gpg --batch --with-colons --import-options show-only --import "$REPO_DIR/keys/$k.asc" 2>/dev/null \
        | awk -F: '$1 == "fpr" { print $10; exit }')"
    spaced="$(printf '%s' "$fpr" | sed 's/..../& /g; s/ $//')"
    [ -n "$fpr" ] && grep -q "$spaced" "$REPO_DIR/keys/README.md" && pass \
        || fail "keys/$k.asc fingerprint ($fpr) listed in keys/README.md"
done

done_testing
