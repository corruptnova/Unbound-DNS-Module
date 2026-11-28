# Changelog

Notes for module revisions. Releases list the bundled versions on top of
these notes.

## Unreleased

- New look: the WebUI follows Material Design 3 (Material You), in light
  and dark: top app bar with icon buttons, a status card coloured by state,
  M3 switches, radio rows, outlined fields, segmented log tabs, snackbars
  and a bottom bar for unsaved settings. Everything is still local; nothing
  is loaded from the internet.
- Security: the trust anchor check ("Update trust anchor"), which fetches
  data from the internet and parses it, no longer runs as root.
  `unbound-anchor` now runs as an unprivileged user with only network
  access, like list downloads, in a folder of its own; the module reads its
  result back with that user's rights (refusing links) before installing it.
- Security: `custom.conf` can no longer undo where Unbound runs. Desktop
  guides often set `username: ""` or `chroot: ""`; with those, Unbound kept
  root and the whole filesystem, and the only check was that it still
  started. A `custom.conf` that sets `username`, `chroot`, `directory`,
  `pidfile`, `logfile` (files Unbound would open as root), `do-daemonize`,
  `port`, `interface` (Unbound allows every source, safe only on loopback),
  `include` or `remote-control` is now refused when saved, and left out with
  a warning in the WebUI when edited by hand. The module's own values for
  these are also set again after `custom.conf`. If your `custom.conf` has
  such lines, remove them; until then it is not used.
- Fix: a blocklist update started from the WebUI ran inside the root
  manager app's cgroups, so Android killed or froze it along with the app;
  its lock then stayed, and once Android reused its process id for another
  program the WebUI showed "Updating blocklists…" for good. Updates and the
  supervisor now move out of the app's cgroups first, and a lock counts only
  while its holder is still the module's script.
- Fix: the Action button could report "redirect: on" right after turning
  it off, while the rules were already being removed.

## v1.26.2-r8

Security hardening (nothing here was known to be exploited; each closes a
way a future Unbound or curl bug could have been turned into root):

- Root no longer trusts anything the Unbound user can change. Unbound's
  folder (`var/`) now holds only `root.key`. The logs moved to the root-only
  `/data/adb/unbound/log/`, and the control socket to `run/`. Root reads
  `root.key` with Unbound's rights, refusing links, and installs a new one
  by renaming it into place, never following what is there. Before, a
  planted link could make root write, chown or move files outside the
  folder. Old logs are carried over.
- Blocklist downloads no longer run as root. curl runs as an unprivileged
  user ("nobody") through a small new helper, `dropexec`, that drops
  privileges for good.
- The NAT64 discovery exemption only lets through a query for exactly
  `ipv4only.arpa`. Before, any DNS packet containing those bytes skipped
  Unbound and the blocklists.
- Builds and automatic updates check each source tarball's release
  signature against the project's pinned key (NLnet Labs, OpenSSL, expat's
  and curl's maintainers), not only a checksum. A release signed with any
  other key stops the update. GitHub Actions are pinned to commit hashes.

- Much lighter on battery: the supervisor no longer checks everything every
  10 seconds. It reacts at once when Unbound exits or a setting changes,
  checks for stop/disable every 30 seconds without starting any process,
  and runs the firewall rule check, list refresh check and statistics
  snapshot every 5 minutes (about 25 times less CPU in testing).
- Disabling or removing the module in the manager takes effect at once: the
  folder is watched with inotifyd, which costs nothing while idle. Where
  inotifyd is missing, the module checks every 10 seconds.
- If another app or service removes the redirect's firewall rule, it is put
  back within 30 seconds instead of 5 minutes. The IPv6 and DoT-blocking
  rules are now checked too, every 5 minutes.
- Plays well with firewall apps: the checks read the rules with
  iptables-save, which takes no lock, so another app's iptables commands
  are never made to wait or fail. Only the module's own rules that are
  actually gone are put back; other apps' chains and rules, and their order,
  are never touched.
- Fix: restarting Unbound could leave the status showing it as stopped.

## v1.26.2-r7

- When Unbound cannot start, its error stays visible in the WebUI while the
  module retries, instead of briefly disappearing at each attempt.

## v1.26.2-r6

- Query and cache statistics keep counting across Unbound restarts, list
  updates and reboots ("Counted since …", with a Reset button).

## v1.26.2-r5

- Settings page: the root trust anchor status reads the file Unbound writes
  while tracking keys (it showed "No root key found" after the first run).
- The DNS redirect counts as active only once all its rules are in place.

## v1.26.2-r4

- My blocklist: block any domain and its subdomains (`*.example.com` works).
- Settings page: resolver (recursive or DNS-over-TLS to Cloudflare, Quad9,
  ControlD or your own servers), cache, threads, DNSSEC and trust anchor,
  privacy options, blocked-name answer, log level, custom.conf editor.
  Unsuccessful changes are rolled back automatically.
- The installer asks which resolver to use (volume keys, 10 s, default
  recursive).
- Ships `unbound-anchor` for the trust-anchor update button.

## v1.26.2-r3

- IPv6-only mobile networks: Android's NAT64 discovery reaches the carrier,
  so IPv4-only services (GitHub, Proton Mail, Klarna, ...) work.
- Diagnostics view in the WebUI (Log → Diagnostics).
