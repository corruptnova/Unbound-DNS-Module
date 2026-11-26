# Unbound DNS for KernelSU

A KernelSU module (also works with Magisk and APatch) that runs
[Unbound](https://nlnetlabs.nl/projects/unbound/) on your phone as a private,
DNSSEC-validating **recursive resolver**, and sends **all** of the phone's DNS
to it. You can add blocklists and an allowlist from a settings page in the
KernelSU manager.

Older Unbound modules have stopped getting updates. Unbound had several
security releases in 2026, one of them fixing a possible remote code
execution bug. This repo builds Unbound from source, and a daily job publishes
a new module as soon as Unbound or one of its libraries releases an update.
The manager then offers the update like any other.

## What it does

- **Recursive, no middleman.** Unbound looks up names itself, starting from
  the DNS root servers. No Google, Cloudflare or ISP resolver sees your whole
  browsing history. It uses QNAME minimisation and aggressive NSEC, hides its
  identity and version, and validates DNSSEC.
- **All DNS, every app.** Firewall rules send every query on port 53 (UDP and
  TCP, IPv4 and IPv6) to Unbound. Android's Private DNS setting would bypass
  Unbound, so it is turned off while the module runs and restored when you
  disable or remove the module. Outgoing DNS-over-TLS/QUIC (port 853) is
  blocked so nothing slips past.
- **Fail-safe.** The redirect is only in place while Unbound is answering. If
  Unbound crashes or a config change breaks it, the redirect is removed at
  once, so your phone falls back to normal DNS. A supervisor then restarts
  Unbound.
- **Blocklists.** Add any https list in hosts, plain domain, `*.wildcard`,
  adblock (`||domain^`, `@@||domain^` exceptions), dnsmasq or Unbound format.
  Presets are included for OISD, HaGeZi and StevenBlack. Lists refresh on a
  schedule (daily by default). If a download fails, the last good copy stays
  in use. Blocking a domain also blocks its subdomains.
- **Your own blocklist.** Type a domain to block it and everything under it
  (`*.example.com` works too). Your entries override the downloaded lists.
- **Allowlist.** Allowed domains, and their subdomains, are never blocked by
  a list. Between your own blocklist and the allowlist, the more specific
  name wins; on an exact tie the allowlist wins.
- **Recursive or encrypted forwarding.** Keep the default recursive mode, or
  send every lookup over DNS-over-TLS to Cloudflare, Quad9, ControlD's free
  resolver or your own servers. The installer asks (volume keys, 10 seconds,
  default recursive), and you can change it any time on the settings page.
- **Settings page.** Cache size and times, prefetching, serving stale
  answers, threads, DNSSEC (on/off, permissive mode, trust-anchor update and
  reset), query-name minimisation, DNS-rebinding protection, IPv6 to servers,
  what blocked names answer, log level, and an editor for `custom.conf`. If
  Unbound does not come up with new settings within 30 seconds, the previous
  ones are restored automatically.
- **Least privilege.** Unbound is locked into `/data/adb/unbound` (a chroot)
  and runs as an unprivileged user (uid 3003, `inet`) instead of root.
- **Captive portals keep working.** Android's network check and the Wi-Fi
  "sign in to network" app bypass the redirect, so hotel and airport Wi-Fi
  login pages are detected. If a portal still won't load, use the module's
  **Action** button or the WebUI to switch the redirect off, sign in, and
  switch it back on.

## Install

1. Download `unbound-dns-v<version>.zip` from
   [Releases](../../releases/latest).
2. Install it in the KernelSU manager (Modules → Install). The installer
   asks how Unbound should resolve names: Vol+ shows the next option
   (Recursive, Cloudflare, Quad9, ControlD), Vol− chooses. If you press
   nothing for 10 seconds it stays recursive (on an update: your current
   choice). Then reboot.
3. Open the module's WebUI to add blocklists. Nothing is blocked until you add
   one.

Requirements: Android 8.0+ on arm64-v8a, armeabi-v7a or x86_64, with KernelSU,
APatch or Magisk. Magisk has no built-in WebUI, but apps that host module
WebUIs (KsuWebUI, MMRL) work.

## Use

**WebUI** (KernelSU manager → Modules → Unbound DNS → open): shows status, a
redirect on/off switch, query and cache statistics, and memory use. You can
add, remove, enable and disable blocklists, edit your own blocklist and the
allowlist, and read the logs and a diagnostics report there. **Settings**
(top right) opens the Unbound settings page.

**Action button**: turns the DNS redirect off and back on.

**Command line** (as root):

```sh
sh /data/adb/modules/unbound-dns/ctl.sh help
sh /data/adb/modules/unbound-dns/ctl.sh status
sh /data/adb/modules/unbound-dns/ctl.sh list-add https://small.oisd.nl/ "OISD small"
sh /data/adb/modules/unbound-dns/ctl.sh update-lists
sh /data/adb/modules/unbound-dns/ctl.sh block-add '*.example.com'
sh /data/adb/modules/unbound-dns/ctl.sh settings-apply RESOLVER=quad9
sh /data/adb/modules/unbound-dns/ctl.sh anchor-update
```

**Your own Unbound settings** go in `/data/adb/unbound/custom.conf`: edit it
on the settings page (Advanced), where a rejected file is rolled back
automatically, or by hand followed by `ctl.sh restart`. It is read last and
never overwritten. Don't define a `forward-zone` for `"."` there while a
forwarder is chosen on the settings page.

**Local blocklists**: put any list file in `/data/adb/unbound/lists/local/`
and run `ctl.sh rebuild`.

### Files on the phone

| Path | What |
|---|---|
| `/data/adb/modules/unbound-dns/` | module code and binaries (replaced on update) |
| `/data/adb/unbound/custom.conf` | your Unbound settings |
| `/data/adb/unbound/lists/` | blocklist URLs, your blocklist, allowlist, local lists, downloaded copies |
| `/data/adb/unbound/settings.conf` | redirect on/off, refresh interval, settings-page choices |
| `/data/adb/unbound/forwarders.list` | your custom DNS-over-TLS servers |
| `/data/adb/unbound/options.conf` | Unbound config generated from the settings page |
| `/data/adb/unbound/var/` | Unbound log, DNSSEC trust anchor, control socket |
| `/data/adb/unbound/var/module.log` | what the module did and when |

Removing the module deletes `/data/adb/unbound` and restores Private DNS.

## Good to know

- **Recursive is not encrypted.** Queries to the authoritative servers travel
  in plain text, so your network operator can still see which names you look
  up. The gain is that no single DNS company collects all of them. Choosing a
  forwarder flips that trade-off: your network sees nothing, the provider
  sees everything.
- **Mullvad DNS is not offered** because Mullvad shut its public DNS down on
  2 November 2026.
- **Apps with their own DNS-over-HTTPS bypass Unbound.** Chrome's "Use secure
  DNS" and Firefox's DNS over HTTPS are examples. Turn those off if you want
  their lookups to go through Unbound too.
- **IPv6-only mobile networks** (T-Mobile US and many others). Android
  reaches IPv4-only services (GitHub, for example) through 464XLAT, which it
  only starts after asking the carrier's DNS about `ipv4only.arpa`. That one
  lookup is let through to the carrier; every other lookup still goes to
  Unbound. The bypass needs the kernel's iptables string match. If the
  WebUI or `ctl.sh diag` shows it as unsupported, IPv4-only services may not
  load on such networks; switch the redirect off there.
- **Kernels without IPv6 NAT** cannot redirect IPv6 DNS. The module then
  leaves IPv6 DNS alone, so DNS keeps working, and says so in the WebUI.
- **Memory.** Each blocked domain costs about 400 bytes in Unbound. 250,000
  domains is about 100 MB. The WebUI shows the real figure.
- **Other DNS or ad-blocking modules and VPN-based blockers** (AdGuard,
  RethinkDNS, other Unbound or AdGuardHome modules) compete for the same
  traffic. Use one at a time.
- **DNSSEC needs a roughly correct clock.** A phone whose clock is far off at
  boot will get lookup failures until the time is synced.

## How it is built

`scripts/build.sh` cross-compiles with the Android NDK (pinned in
`versions.env`, currently r30, API 26, 16 KB page aligned):

- OpenSSL 3.5 LTS (static, trimmed to what DNSSEC and HTTPS need)
- expat (static)
- Unbound: `unbound`, `unbound-control` and `unbound-anchor`, linked only
  against Android's libc
- curl: an HTTPS-only client used for list downloads. It verifies
  certificates against Android's system CA store.

Every source tarball is verified against the sha256 in `versions.env`.
Unbound and OpenSSL are also checked against the checksums their projects
publish.

```sh
scripts/build.sh all        # or arm64-v8a / armeabi-v7a / x86_64
scripts/package.sh          # -> dist/unbound-dns-<version>.zip, update.json
sh tests/run.sh             # shell tests (prefers busybox ash)
node tests/webui/webui.test.cjs   # WebUI test (needs Playwright)
```

### Releases and automatic updates

- `versions.env` pins every upstream version. The module version is
  `v<unbound>-r<revision>`.
- **check-updates** (daily, on `main` only) runs
  `scripts/update-versions.sh`. When anything is newer, it commits
  `versions.env` to `main`, builds, runs all tests including the emulator
  test, and publishes a GitHub release. A new Unbound resets the revision to
  1; a dependency-only update increments it. It needs permission to push to
  `main`: if branch protection requires pull requests, allow GitHub Actions
  to push, or run the steps by hand.
- **release** publishes on a pushed `v*` tag, or when run by hand. Use it
  after changing module scripts: bump `MODULE_REVISION`, commit, then tag.
- **ci** runs on every push. It does shellcheck and the shell tests
  (including a real Unbound answering from the shipped config), the WebUI
  test, builds for all three ABIs, and a smoke test on an Android 14 emulator.
  The emulator test checks that apps' DNS reaches Unbound, that blocklists
  download over TLS on the device, that killing Unbound or breaking its
  config leaves DNS working, and that disabling the module restores
  everything.
- `module.prop`'s `updateJson` points at the latest release's `update.json`,
  so the manager offers new releases automatically.

## License

MIT for this repository (see `LICENSE`). The module zip also includes the
licenses of Unbound (BSD), OpenSSL (Apache 2.0), expat (MIT) and curl
(curl license) in `licenses/`.
