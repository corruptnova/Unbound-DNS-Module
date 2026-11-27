#!/bin/sh
# The privilege-drop helper itself (src/dropexec.c), built for the host.
# Needs a C compiler and root; skipped otherwise.
. "${TESTS_DIR:-$(dirname "$0")}/lib.sh"

CC="${CC:-$(command -v cc || command -v gcc || command -v clang)}"
[ -n "$CC" ] || { echo "test_dropexec.sh: skipped (no C compiler)"; exit 0; }
[ "$(id -u)" = 0 ] || { echo "test_dropexec.sh: skipped (needs root)"; exit 0; }

DX="$TMP/dropexec"
assert_ok "builds without warnings" "$CC" -O2 -Wall -Wextra -Werror -o "$DX" "$REPO_DIR/src/dropexec.c"

# A root-only folder, like /data/adb on the phone.
P="$TMP/private"; mkdir -p "$P/bin" "$P/var"; chmod 0700 "$P"
# The test program is a copy of the shell: multi-call binaries such as
# uutils' id pick their tool from the name they were run under, which is
# /dev/fd/N here (curl, the real user, does not care).
cp "$(command -v dash || command -v sh)" "$P/bin/sh"
ids() { "$DX" run 9999 9999 "$1" "$P/bin/sh" -c "id $2"; }
echo ca-data > "$P/ca.pem"; chmod 0644 "$P/ca.pem"

assert_eq "runs as the given user" "9999" "$(ids 3003 -u)"
assert_eq "with only the given groups" "3003 9999" "$(ids 3003 -G | tr ' ' '\n' | sort -n | tr '\n' ' ' | sed 's/ $//')"
assert_eq "no supplementary groups with -" "9999" "$(ids - -G)"
status="$("$DX" run 9999 9999 - /bin/sh -c 'grep -E "^(CapEff|CapPrm|NoNewPrivs):" /proc/self/status' | tr -s ' \t' ' ')"
assert_contains "no capabilities left" "CapEff: 0000000000000000" "$status"
assert_contains "no permitted capabilities" "CapPrm: 0000000000000000" "$status"
assert_contains "cannot gain privileges" "NoNewPrivs: 1" "$status"
assert_eq "file handed over on fd 3" "ca-data" "$("$DX" run 9999 9999 - /bin/sh -c 'cat /proc/self/fd/3' 3< "$P/ca.pem")"
assert_fails "root-only folder stays closed" "$DX" run 9999 9999 - /bin/cat "$P/ca.pem"
assert_fails "refuses uid 0" "$DX" run 0 9999 - /bin/true
assert_fails "refuses gid 0" "$DX" run 9999 0 - /bin/true
assert_fails "refuses group 0" "$DX" run 9999 9999 3003,0 /bin/true
assert_fails "refuses a bad number" "$DX" run 99x 9999 - /bin/true
assert_fails "refuses a relative path" "$DX" run 9999 9999 - true
assert_fails "missing program" "$DX" run 9999 9999 - "$P/bin/nothing"

# read: a folder owned by the user, like var/ for Unbound.
chown 3003:3003 "$P/var"; chmod 0750 "$P/var"
printf 'key\n' > "$P/var/root.key"; chown 3003:3003 "$P/var/root.key"
rd() { "$DX" read 3003 3003 "$P/var" "$1" "${2:-65536}"; }
assert_eq "reads a plain file" "key" "$(rd root.key)"
echo secret > "$P/secret"; chmod 0600 "$P/secret"
ln -s "$P/secret" "$P/var/link"
assert_fails "refuses a symbolic link" rd link
mkfifo "$P/var/pipe"
timeout 5 "$DX" read 3003 3003 "$P/var" pipe 65536 >/dev/null 2>&1; rc=$?
[ "$rc" = 125 ] && pass || fail "refuses a pipe without blocking (exit $rc)"
mkdir "$P/var/dir"
assert_fails "refuses a folder" rd dir
head -c 2000 /dev/zero > "$P/var/big"; chown 3003:3003 "$P/var/big"
assert_fails "refuses a file over the limit" rd big 1000
assert_ok "accepts a file at the limit" rd big 2000
printf 'x\n' > "$P/var/rootonly"; chmod 0600 "$P/var/rootonly"
assert_fails "reads with the user's rights" rd rootonly
assert_fails "refuses a path" rd ../secret
assert_fails "refuses .." rd ..

done_testing
