#!/bin/sh
# Run every tests/test_*.sh. Prefers busybox ash in standalone mode, which is
# how the root managers run module scripts on the phone.
cd "$(dirname "$0")" || exit 1
if command -v busybox >/dev/null 2>&1; then
    SHELL_CMD="busybox sh"
    export ASH_STANDALONE=1
else
    SHELL_CMD="sh"
    echo "busybox not found; running tests with sh" >&2
fi

status=0
for t in test_*.sh; do
    [ -n "${1:-}" ] && [ "$t" != "$1" ] && continue
    if ! TESTS_DIR="$PWD" $SHELL_CMD "./$t"; then
        status=1
    fi
done
exit $status
