# Minimal test helpers. Sourced by tests/test_*.sh.
# shellcheck shell=sh

TESTS_DIR="${TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
LIB_DIR="$REPO_DIR/module/lib"
FAILS=0
PASSES=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { PASSES=$((PASSES + 1)); }
fail() { FAILS=$((FAILS + 1)); printf 'FAIL: %s\n' "$*" >&2; }

# assert_eq NAME EXPECTED ACTUAL
assert_eq() {
    if [ "$2" = "$3" ]; then pass; else
        fail "$1"
        printf -- '--- expected\n%s\n--- actual\n%s\n' "$2" "$3" >&2
    fi
}

# assert_contains NAME NEEDLE HAYSTACK
assert_contains() {
    case "$3" in *"$2"*) pass ;; *) fail "$1: missing '$2' in: $3" ;; esac
}

assert_not_contains() {
    case "$3" in *"$2"*) fail "$1: unexpected '$2' in: $3" ;; *) pass ;; esac
}

# assert_ok NAME CMD...  /  assert_fails NAME CMD...
assert_ok() { _n="$1"; shift; if "$@" >/dev/null 2>&1; then pass; else fail "$_n (exit $?)"; fi; }
assert_fails() { _n="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$_n (expected failure)"; else pass; fi; }

assert_json() {
    if printf '%s' "$2" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then pass
    else fail "$1: invalid JSON: $2"; fi
}

done_testing() {
    printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$PASSES" "$FAILS"
    [ "$FAILS" -eq 0 ]
}
