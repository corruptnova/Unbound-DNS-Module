# Unbound DNS KernelSU Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A repo that cross-compiles current Unbound for Android and packages it as a KernelSU module that runs a recursive, validating resolver, redirects all DNS to it, and manages blocklists from a WebUI.

**Architecture:** Shell build scripts drive the NDK (static OpenSSL/expat/curl, Unbound linked against them). The module is POSIX shell run under the root manager's busybox: one control script (`ctl.sh`) owns every action; boot, the Action button and the WebUI all call it. GitHub Actions builds, tests (host Unbound + emulator) and auto-releases on upstream bumps.

**Tech Stack:** Android NDK r30, OpenSSL 3.5 LTS, expat, curl, Unbound; busybox ash/awk; iptables; vanilla HTML/JS WebUI on `ksu.exec`; GitHub Actions; Playwright for WebUI tests.

**Spec:** `docs/superpowers/specs/2026-11-26-unbound-kernelsu-module-design.md`

## Global Constraints

- Module id `unbound-dns`; data/chroot dir `/data/adb/unbound`; Unbound user `inet` (uid/gid 3003); listen port 5335 on 127.0.0.1 and ::1 (when present).
- minSdk / `__ANDROID_API__` 26; ABIs `arm64-v8a`, `armeabi-v7a`, `x86_64`; 16 KB page-aligned.
- Version `v<unbound>-r<rev>`; versionCode `major*1000000 + minor*10000 + patch*100 + rev`.
- Every source download verified by sha256 from `versions.env`; list downloads only over https with certificate verification.
- Scripts must run under busybox ash (`ASH_STANDALONE=1`); `ctl.sh` re-execs itself under the manager's busybox.
- Never leave the redirect in place while Unbound is not answering.
- User input reaching the shell (URLs, names, domains) is validated in `ctl.sh` regardless of what the WebUI checked.

## Review Focus

- Blocklist with CRLF line endings, BOM, inline comments, uppercase, trailing dots, IPs instead of names → parsed or skipped, never emitted as invalid Unbound config. (Task 2 fixtures.)
- Allowlisted name that is a subdomain of a blocked name, and a blocked name under an allowlisted parent → allow wins in both. (Task 2.)
- URL or domain containing `'`, `;`, `$(`, spaces or newlines from the WebUI → rejected by `ctl.sh`, nothing written. (Task 3.)
- Unbound that cannot start (bad `custom.conf`) → no redirect applied, phone DNS keeps working. (Task 3 stub test, Task 6 emulator.)
- Device without IPv6 NAT or without `::1` → IPv4 redirect still applied, Unbound still starts. (Task 3 stub test.)

---

### Task 1: Cross-compile toolchain and binaries

**Files:** Create `versions.env`, `scripts/lib.sh`, `scripts/build.sh`, `.gitignore`.

**Interfaces:**
- Produces: `scripts/build.sh <abi>` → `out/<abi>/{unbound,unbound-control,unbound-checkconf,curl}`; env `ANDROID_NDK_HOME`, `JOBS`, `<NAME>_SRC_DIR` (use an extracted tree instead of downloading; dev only).
- `scripts/lib.sh`: `log`, `die`, `fetch_verified <url> <sha256> <dest>`, `abi_triple <abi>`, `version_code <unbound_version> <rev>`.

- [ ] Build `arm64-v8a` locally; `file out/arm64-v8a/unbound` reports `ELF 64-bit ... ARM aarch64 ... interpreter /system/bin/linker64`; `llvm-readelf -d` shows only bionic `NEEDED` libs (libc, libm, libdl).
- [ ] Build `x86_64` and `armeabi-v7a` the same way.
- [ ] Commit.

### Task 2: Blocklist parser and merger

**Files:** Create `module/lib/blocklist.awk`, `module/lib/lists.sh`; tests `tests/test_blocklist.sh`, `tests/fixtures/*`, `tests/lib.sh`, `tests/run.sh`.

**Interfaces:**
- `blocklist.awk` reads any list format on stdin, prints `B <domain>` / `A <domain>` lines.
- `lists_merge <out.conf> <blockfiles...> -- <allowfiles...>` writes `server:` + `local-zone: "<d>." always_nxdomain` / `transparent` lines and prints the blocked count.

- [ ] Tests: hosts (`0.0.0.0`, `127.0.0.1`, `::`, multiple names per line, localhost names skipped), plain domains, `*.d` wildcards, adblock `||d^`, `||d^$important`, `@@||d^` → allow, modifiers/regex/paths skipped, dnsmasq `address=/d/`, unbound `local-zone:` lines, CRLF/BOM/uppercase/trailing dot, invalid labels skipped.
- [ ] Tests: subdomain of blocked parent pruned; allow subtree removes blocks; allow under block → `transparent`; `example-foo.com` not treated as child of `example.com`.
- [ ] Run `tests/run.sh` under busybox: all pass. Commit.

### Task 3: Control script, redirect, supervisor

**Files:** Create `module/ctl.sh`, `module/lib/common.sh`, `module/lib/redirect.sh`, `module/lib/daemon.sh`; tests `tests/test_ctl.sh` with stub `iptables`, `unbound`, `unbound-control`, `settings`, `curl` on `PATH`.

**Interfaces (`ctl.sh` subcommands, JSON on stdout where noted):**
`setup`, `daemon`, `stop`, `restart`, `status` (JSON), `redirect on|off`, `lists` (JSON), `list-add <url> [name]`, `list-remove <id>`, `list-enable <id> 0|1`, `allow-add <domain>`, `allow-remove <domain>`, `update-lists [--bg] [--force]`, `rebuild`, `set refresh_hours <1..168>`, `log [n]`, `uninstall-cleanup`.
Env overrides for tests: `UNBOUND_DATA`, `UNBOUND_MODDIR`, `UNBOUND_NO_BUSYBOX_REEXEC=1`.

- [ ] Tests: injection strings rejected with non-zero exit and files unchanged; `status`/`lists` output parses as JSON; `redirect off` removes chains (stub log), `on` adds udp+tcp 53 REDIRECT with uid 3003 RETURN first; IPv6 NAT failure leaves IPv4 rules; failed Unbound start never calls the redirect; Private DNS saved once and restored by `uninstall-cleanup`.
- [ ] Commit.

### Task 4: Unbound configuration

**Files:** Create `module/conf/unbound.conf`, `module/conf/control.conf`, `module/conf/custom.conf`; test `tests/test_unbound_live.sh` (host Unbound; skipped if absent).

- [ ] Test: `unbound-checkconf` passes on the shipped config (paths rewritten to a temp dir, user/chroot cleared); live server answers NXDOMAIN for a blocked name, local data for an allowlisted name under a blocked parent, and `reload_keep_cache` succeeds over the unix control socket.
- [ ] Commit.

### Task 5: Module packaging and installer hooks

**Files:** Create `module/module.prop.in`, `module/customize.sh`, `module/service.sh`, `module/uninstall.sh`, `module/action.sh`, `module/META-INF/com/google/android/{update-binary,updater-script}`, `scripts/package.sh`.

**Interfaces:** `scripts/package.sh` → `dist/unbound-dns-<version>.zip`, `dist/update.json`, `dist/changelog.md`. Reads `versions.env`, `out/*/`, `GITHUB_REPOSITORY` (default `corruptnova/Unbound-DNS-Module`).

- [ ] Package from local build; `unzip -l` shows all three ABIs, `module.prop` has the computed versionCode, `update.json` parses.
- [ ] Commit.

### Task 6: WebUI

**Files:** Create `module/webroot/{index.html,app.js,style.css}`; test `tests/webui/webui.test.mjs` (Playwright, mocked `window.ksu`).

- [ ] Test: renders status and lists from mocked JSON; adding a preset issues `list-add` with a single-quoted URL; a domain with a quote is shell-quoted safely; screenshot at phone width looks right in light and dark.
- [ ] Commit.

### Task 7: CI, auto-update, emulator smoke test, docs

**Files:** Create `.github/workflows/{ci.yml,release.yml,check-updates.yml}`, `scripts/update-versions.sh`, `tests/emulator/smoke.sh`, `README.md`, `LICENSE`.

- [ ] `update-versions.sh` locally against reachable sources fills/keeps pins and bumps revision rules (unbound bump → rev 1; deps-only → rev+1; nothing → no change).
- [ ] Push; CI green across lint, tests, three builds, package and emulator smoke (blocked name unresolvable via `ping`, Unbound counts queries, killing Unbound restarts it, bad config leaves DNS working).
- [ ] Commit pins produced by the first CI run if any were missing.
