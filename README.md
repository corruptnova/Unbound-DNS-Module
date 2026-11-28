# Unbound DNS for KernelSU

A KernelSU module (also works with Magisk and APatch) that runs a current
[Unbound](https://nlnetlabs.nl/projects/unbound/) on your phone as a private,
DNSSEC-validating resolver and sends **all** of the phone's DNS to it.
Unbound is built from source, and a daily job publishes a new release
whenever Unbound or one of its libraries updates, so the module never falls
behind on security fixes.

## Features

- **Recursive by default:** Unbound resolves names itself from the root
  servers. Optionally, it forwards over DNS-over-TLS to Cloudflare, Quad9,
  ControlD or your own servers.
- **All apps, all DNS:** port 53 (IPv4 and IPv6) is redirected to Unbound.
  Private DNS is turned off while the module runs, and outgoing port 853 is
  blocked.
- **Fail-safe:** the redirect only exists while Unbound answers. If Unbound
  stops, the phone falls back to normal DNS until Unbound is restarted.
- **Blocklists:**
  - downloaded lists in hosts, domain, adblock, dnsmasq or Unbound format,
    refreshed daily;
  - your own blocklist and an allowlist.
  - A blocked domain includes its subdomains (`*.example.com` works too).
- **WebUI:**
  - status, redirect switch, lists, logs and diagnostics;
  - a **Settings** page for the resolver, cache, threads, DNSSEC and trust
    anchor, privacy options, blocked-name answer, log level and
    `custom.conf`. A change that keeps Unbound from starting is rolled back
    automatically.
- **Least privilege:** Unbound runs chrooted in `/data/adb/unbound` as an
  unprivileged user.
- **Works with captive portals and IPv6-only carriers:** Wi-Fi login pages
  and 464XLAT keep working.

## Install

1. Download the zip from [Releases](../../releases/latest) and install it in
   your root manager.
2. Choose a resolver when asked (Vol+ = next, Vol− = choose; no key for 10 s
   keeps Recursive or your current choice). Reboot.
3. Add blocklists in the WebUI. Nothing is blocked until you do.

Requirements: Android 8.0+ on arm64-v8a, armeabi-v7a or x86_64. Magisk users
need a WebUI host app such as KsuWebUI or MMRL.

## Use

- **WebUI:** KernelSU manager → Modules → Unbound DNS.
- **Action button:** turns the redirect off and on, for example to sign in
  to hotel Wi-Fi.
- **Command line** (as root): `sh /data/adb/modules/unbound-dns/ctl.sh help`.
  For example:

  ```sh
  ctl.sh status
  ctl.sh block-add '*.example.com'
  ctl.sh settings-apply RESOLVER=quad9
  ctl.sh diag          # troubleshooting report
  ```

- **Your own Unbound settings:** edit them in Settings → Advanced, or in
  `/data/adb/unbound/custom.conf` followed by `ctl.sh restart`.
- **Local lists:** drop files into `/data/adb/unbound/lists/local/`, then run
  `ctl.sh rebuild`.

Everything you configure lives in `/data/adb/unbound/`. Removing the module
deletes it and restores Private DNS.

## Good to know

- **Recursive is not encrypted.** Your network can see the names you look
  up, but no single DNS company gets all of them. A forwarder is the
  opposite: your network sees nothing, and the provider sees everything.
- **Apps with their own DNS-over-HTTPS bypass Unbound**, such as Chrome's
  "Use secure DNS".
- **Some kernels lack IPv6 NAT or string match.** IPv6 DNS, or the 464XLAT
  helper, then can't be handled. The WebUI says so, and DNS keeps working.
- **Memory:** about 400 bytes per blocked domain (250,000 domains ≈ 100 MB).
- **Use one DNS blocker at a time:** other DNS modules and VPN-based blockers
  conflict with this one.
- **The clock must be roughly right.** DNSSEC fails with a badly wrong clock.
- **Mullvad isn't offered as a forwarder:** its public DNS closed on
  2 November 2026.

## Building

```sh
scripts/build.sh all     # cross-compile with the pinned NDK (versions.env)
scripts/package.sh       # -> dist/unbound-dns-<version>.zip
sh tests/run.sh          # shell tests; node tests/webui/webui.test.cjs for the WebUI
```

What goes into the zip:
- **Unbound** (`unbound`, `unbound-control`, `unbound-anchor`), statically
  linked with **OpenSSL 3.5 LTS** and **expat**;
- an HTTPS-only **curl** for list downloads, run as an unprivileged user
  through a small helper (`dropexec`, in `src/`), like `unbound-anchor`
  when it checks the trust anchor with IANA.

Every source tarball must carry a good release signature from its project's
key in `keys/` (see `keys/README.md`) and match the sha256 pinned in
`versions.env`. GitHub Actions are pinned to commit hashes.

**Releases:**
- **ci** runs on every push: lint, tests, builds for all three
  architectures, and an Android emulator smoke test.
- **check-updates** runs daily on `main`. It pins new upstream versions
  whose signatures check out, then builds, tests and publishes a release.
  A release signed with an unknown key stops it until `keys/` is updated.
- **release** publishes when you push a `v<unbound>-r<revision>` tag. After
  script-only changes, bump `MODULE_REVISION` first.

## License

MIT (`LICENSE`). The zip includes the licenses of Unbound, OpenSSL, expat and
curl.
