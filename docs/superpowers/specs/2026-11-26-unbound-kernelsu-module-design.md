# Unbound DNS module for KernelSU — design

Date: 2026-11-26

## Intent

Existing Unbound modules for rooted Android are outdated. Unbound shipped many
security releases in 2026 (1.25.0 → 1.26.2, including a possible RCE in DNSSEC
validation fixed in 1.25.1), so an outdated resolver is a real risk. This repo
builds a KernelSU module that runs a **current** Unbound as a **private,
validating, recursive resolver** on the phone and sends **all** of the phone's
DNS to it, with **user-managed blocklists** and a **settings page** in the
KernelSU manager.

The defining property is freshness: builds come from upstream source and a
scheduled job publishes a new module when Unbound (or a bundled library)
releases.

## Goals

- Recursive resolution from the root (no Google/Cloudflare upstream), DNSSEC
  validation, QNAME minimisation, aggressive NSEC, hidden identity/version.
- Redirect all DNS (UDP+TCP port 53, IPv4+IPv6) to Unbound. Turn Android
  Private DNS off while active (it would bypass the redirect); restore it on
  uninstall. Reject outbound port 853 (DoT/DoQ) from everything but Unbound.
- Fail safe: if Unbound dies, remove the redirect so the phone keeps working,
  then restart Unbound with backoff.
- Blocklists by URL, refreshed on a schedule (default daily), plus local
  files dropped in a folder. Formats: hosts, plain domains, adblock `||d^`
  (including `@@||d^` exceptions → allowlist). Last good copy kept on failure.
- Allowlist that always wins over blocklists.
- KernelSU WebUI: status, redirect on/off (for captive portals), blocklists
  (add/remove/enable, presets, update now, refresh interval), allowlist, log.
- Automatic builds: GitHub Actions cross-compiles with the Android NDK and a
  daily job bumps versions, builds, tests and publishes a release. The manager
  offers the update via `updateJson`.

## Non-goals

- Encrypted upstream (DoT/DoH forwarding). Possible later via `custom.conf`.
- Intercepting apps that do their own DNS-over-HTTPS (e.g. Chrome Secure DNS);
  port-based redirection cannot see it. Documented.
- DNS64 for IPv6-only carriers. Android's NAT64 prefix discovery queries
  `ipv4only.arpa`; once redirected, discovery may fail on carriers that rely on
  DNS64 (rather than PREF64 in router advertisements). Documented as a known
  limitation; the redirect toggle is the workaround. Follow-up candidate.
- Mounting anything into `/system` (KernelSU now needs a metamodule for that).

## Anti-goals

- Breaking DNS on the phone when something fails (bad list, crash, update).
- Silent staleness: a build that quietly stops tracking upstream.
- Unverified downloads: sources are pinned by sha256; blocklists are fetched
  with TLS certificate verification (our own curl + Android's CA store).

## Constraints

- Module format shared by KernelSU, Magisk and APatch. WebUI uses KernelSU's
  `ksu.exec` JS API (also implemented by APatch, KsuWebUI and MMRL).
- Module scripts run under the root manager's busybox in standalone ash mode;
  WebUI commands may run under `/system/bin/sh`, so the control script re-execs
  itself under busybox.
- `/data/adb` is root-only (0700), which matters once Unbound drops privileges.
- No device or emulator with KVM in the authoring container; CI provides an
  emulator smoke test.

## Approaches considered

1. **Cross-compile from source in CI with the NDK (chosen).** Full control of
   versions, static OpenSSL/expat, reproducible from pinned versions, can follow
   upstream within a day.
2. Repackage Termux's prebuilt `unbound` package. Fast, but inherits Termux's
   update cadence (the staleness problem again), its `/data/data/com.termux`
   prefix and its shared libraries.
3. Static musl build (e.g. zig cc). Works, but it is not the platform toolchain
   and gains nothing over the NDK here.

The user handed over the how; approach 1 is the author's call.

## Design

### Build

- `versions.env` pins Unbound, OpenSSL (3.5 LTS series), expat, curl, the NDK
  and the module revision, each source with a sha256.
- `scripts/build.sh <abi>` downloads + verifies sources, then builds OpenSSL
  and expat as static libraries, Unbound (`unbound`, `unbound-control`,
  `unbound-checkconf`) and a minimal HTTPS-only `curl`, all linked statically
  against the deps and dynamically against bionic. API level 26. ABIs:
  `arm64-v8a`, `armeabi-v7a`, `x86_64`. Binaries are stripped.
- `scripts/package.sh` assembles one zip for all ABIs, writes `module.prop`
  version (`v<unbound>-r<rev>`) and versionCode
  (`major*1e6 + minor*1e4 + patch*100 + rev`), and `update.json`.
- Root trust anchor (`root.key`) comes from Ubuntu's `dns-root-data` at build
  time; Unbound keeps it current via RFC 5011 (`auto-trust-anchor-file`).
  `unbound-anchor` is not needed at runtime.

### CI (GitHub Actions)

- `ci.yml` (push/PR): shellcheck, list-parser tests, config tests against a host
  Unbound, cross-build all ABIs, package, emulator smoke test (x86_64).
- `release.yml` (tag push / manual): build + publish a GitHub release with the
  zip and `update.json`.
- `check-updates.yml` (daily + manual): `scripts/update-versions.sh` finds the
  latest upstream versions (via `git ls-remote`, no API rate limits), pins
  sha256 (checked against upstream `.sha256` files where published), commits
  `versions.env` if anything changed, then builds and releases in the same run.
  Unbound bump → revision resets to 1; dependency-only bump → revision + 1.
- `updateJson` points at
  `https://github.com/<repo>/releases/latest/download/update.json`, so no bot
  commits are needed for update notifications.

### On-device layout

- Module code: `/data/adb/modules/unbound-dns/` (replaced on update).
- Persistent data and Unbound chroot: `/data/adb/unbound/`
  - `unbound.conf` (copied from the module on every start), `custom.conf`
    (user's, never overwritten), `blocklist.conf` (generated), `control.conf`
  - `settings.conf` (key=value, written only through the control script)
  - `lists/sources.list` (`enabled<TAB>name<TAB>url`), `lists/allow.list`,
    `lists/local/` (user files), `lists/cache/` (downloaded copies + metadata)
  - `var/` (owned by the Unbound user): `root.key`, `unbound.log`,
    control socket

### Runtime

- Unbound listens on `127.0.0.1@5335` and `::1@5335`, chroots to
  `/data/adb/unbound` and drops to uid/gid 3003 (`inet`). The `inet` group is
  what grants network access on older kernels with paranoid networking, and
  no other process runs as uid 3003, so iptables can exempt it by uid.
- Redirect: `iptables`/`ip6tables` nat chain `UNBOUND_DNS` in `OUTPUT`:
  RETURN for uid 3003 and for Android's network stack (uid 1073) and captive
  portal login app, so network validation and "sign in to network" keep
  working; REDIRECT udp/tcp 53 → 5335. A filter chain rejects 853 for other
  uids. If IPv6 NAT is unavailable, IPv6 DNS is left alone (logged) rather than
  blocked, so IPv6-only networks still resolve.
- Supervisor (`service.sh` → `ctl.sh daemon`): waits for boot, prepares the
  chroot, starts `unbound -d`, applies the redirect once `unbound-control
  status` succeeds, polls every 10 s; on exit removes the redirect, restarts
  with backoff. It also runs the blocklist refresh when due and stops
  everything when the module is disabled or marked for removal.
- Blocklist build: download (curl, TLS verified against Android's CA store,
  size and time limits) → parse with busybox awk → lowercase/validate →
  dedupe and drop subdomains already covered by a blocked parent → remove
  allowlisted names → write `local-zone: "d." always_nxdomain`; allowlist
  entries become `transparent` zones so they override a blocked parent →
  `unbound-checkconf` → atomic swap → `unbound-control reload_keep_cache`.
  Any failure keeps the previous `blocklist.conf`.
- `action.sh` (manager's Action button): toggles the redirect.
- `uninstall.sh`: stop, remove rules, restore Private DNS, delete
  `/data/adb/unbound`.

### Unbound defaults

Single thread, small caches suitable for a phone (msg 8m, rrset 16m),
`prefetch`, `prefetch-key`, `serve-expired` with a 1.8 s client timeout
(RFC 8767) for flaky mobile links, `edns-buffer-size: 1232`,
`minimal-responses`, `aggressive-nsec`, `qname-minimisation`,
`harden-below-nxdomain`, `hide-identity/version`. `custom.conf` for anything
else (e.g. rebinding protection, forwarders).

### WebUI

Plain HTML/CSS/JS in `webroot/`, no build step, follows system light/dark.
All actions go through `ctl.sh` subcommands that return JSON; user input is
shell-quoted in JS **and** validated in the shell script. Presets: OISD
small/big, Hagezi light/normal/pro, StevenBlack. No list is enabled by default.

### Testing

- Parser and settings logic: shell tests run with busybox ash in CI and locally.
- Generated config: `unbound-checkconf` + a live host Unbound answering
  NXDOMAIN for blocked names and resolving allowlisted ones.
- WebUI: Playwright against a mocked `ksu.exec`.
- Emulator (CI, x86_64, rooted AOSP image): install the module files, start the
  supervisor, check that `ping` cannot resolve a blocked name, that queries hit
  Unbound, and that killing Unbound removes the redirect.

## Calls made by the author (for review)

- Port 5335, uid 3003 (`inet`), chroot to `/data/adb/unbound`.
- Exempting Android's network stack and captive-portal login app from the
  redirect so captive portals are detected; their lookups reveal nothing
  personal.
- Rejecting port 853 while active.
- NXDOMAIN for blocked names; no blocklists enabled by default.
- Bundling our own curl to get TLS verification for list downloads.
- ABIs arm64-v8a, armeabi-v7a, x86_64; API 26; OpenSSL 3.5 LTS series.
