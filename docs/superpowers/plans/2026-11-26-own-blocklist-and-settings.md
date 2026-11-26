# Own Blocklist, Settings Page and Installer Choice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Own domain blocklist, a WebUI settings page with safe apply/rollback, DoT forwarder presets, trust-anchor tools, and a volume-key resolver choice in the installer.

**Architecture:** Settings live in `settings.conf` (+ `forwarders.list`); `ctl.sh` validates and renders them into `options.conf`, restarts Unbound and rolls back if it does not come up. The WebUI's new `settings.html` and the installer both go through `ctl.sh settings-apply`.

**Tech Stack:** busybox ash/awk, Unbound 1.26 options, `unbound-anchor`, vanilla JS, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-26-own-blocklist-and-settings-design.md`

## Global Constraints

- Every setting value is validated in `ctl.sh` against a fixed set or numeric range; `settings-apply` writes nothing unless all values pass.
- Forwarders over DNS-over-TLS only, port 853 default; certificate bundle at `/data/adb/unbound/ca.pem`.
- Presets: cloudflare (1.1.1.1, 1.0.0.1, 2606:4700:4700::1111, ::1001 #cloudflare-dns.com), quad9 (9.9.9.9, 149.112.112.112, 2620:fe::fe, 2620:fe::9 #dns.quad9.net), controld (76.76.2.0, 76.76.10.0, 2606:1a40::0, 2606:1a40:1::0 #p0.freedns.controld.com).
- Installer timeout 10 s per prompt step (env `UNBOUND_INSTALL_TIMEOUT` for tests).
- Apply rollback window 30 s (env `UNBOUND_APPLY_TIMEOUT` for tests).

## Review Focus

- Custom forwarder line with shell metacharacters, newline, missing TLS name, or a bad IP → rejected, nothing written. (Task 3)
- `custom.conf` saved with a syntax error → previous file restored, Unbound running again, error returned. (Task 3)
- Settings apply while the daemon is not running (installer) → files written, no restart attempted. (Task 3/4)
- Own block equal to an allowlisted name → allow wins; own block under allowlisted parent → blocked. (Task 2)
- Volume keys never pressed / `getevent` missing → default kept, install continues. (Task 4)

---

### Task 1: Ship unbound-anchor
`scripts/build.sh`, `scripts/package.sh`, `module/customize.sh` (required binaries). Verify `file out/*/unbound-anchor`.

### Task 2: Own blocklist
`module/lib/merge.awk` (tag `U`, `-v blocktype`), `module/lib/lists.sh` (`block.list`, block type from settings, validation regex), `module/lib/common.sh` (`normalise_domain` accepts leading `*.`), `module/ctl.sh` (`block-add`, `block-remove`, `lists` JSON `block`). Tests in `tests/test_blocklist.sh`, `tests/test_ctl.sh`.

### Task 3: Settings, options.conf, apply/rollback, custom.conf, anchor
`module/lib/settings.sh` (defaults, validation `setting_valid KEY VALUE`, `write_options_conf`, `settings_json`, `forwarders_for MODE`), `module/lib/daemon.sh` (CA bundle into chroot, `options.conf` at setup, `do-ip6` from setting), `module/conf/unbound.conf` (include `options.conf`), `module/ctl.sh` (`settings`, `settings-apply`, `settings-reset`, `custom-get`, `custom-set`, `anchor-update`, `anchor-reset`). Tests: `tests/test_ctl.sh` (validation, rendering, rollback via stub failure pattern, anchor stub), `tests/test_unbound_live.sh` (rendered options pass `unbound-checkconf`; `always_null` answers 0.0.0.0).

### Task 4: Installer resolver choice
`module/customize.sh` (`vol_key`, menu). Tests in `tests/test_install.sh` with a stub `getevent` fed from a script file.

### Task 5: WebUI
`module/webroot/common.js` (shared helpers), `index.html`/`app.js` (My blocklist card, settings link, resolver shown in status), `settings.html`/`settings.js`. Test: `tests/webui/webui.test.cjs` drives both pages against the real `ctl.sh`.

### Task 6: Emulator, docs, release
`tests/emulator/smoke.sh` (switch to Quad9 over DoT and back, own blocklist, anchor update), README, `MODULE_REVISION=4`, push, CI green.
