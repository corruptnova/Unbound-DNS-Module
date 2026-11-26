# Own blocklist, resolver settings and installer choice — design

Date: 2026-11-26. Builds on `2026-11-26-unbound-kernelsu-module-design.md`.
Approved by the user in conversation.

## Intent

The user wants to block individual domains without a list URL, to tune
Unbound from the WebUI instead of hand-editing config, to choose an encrypted
public resolver instead of recursion, and to make that choice already in the
installer.

## Goals

1. **My blocklist** (main WebUI page). Each entry blocks the domain and every
   subdomain. `*.example.com` is accepted and means the same as
   `example.com`. Partial-label patterns (`ads*.x`) are not possible in
   Unbound and are rejected.
   Precedence: own entries override the downloaded lists; between own
   blocklist and allowlist the more specific name wins; an exact tie goes to
   the allowlist.
2. **Resolver mode**: recursive (default) or DNS-over-TLS forwarding to
   Cloudflare, Quad9, ControlD free unfiltered (p0) or custom servers
   (address + TLS name). Mullvad is excluded: its public DNS shut down on
   2026-11-02. Certificates are verified against Android's CA store; DNSSEC
   validation stays on top.
3. **Installer choice**: Vol+ cycles Recursive → Cloudflare → Quad9 → ControlD,
   Vol− chooses. 10 s without a key press keeps the default: recursive on a
   fresh install, the current choice on an update. No volume key reader
   (`getevent`) → no question, default applies.
4. **Settings page** (`settings.html`): resolver; cache size
   (small/medium/large), min/max TTL, prefetch, serve-stale; threads 1–4;
   DNSSEC on/off, permissive mode, trust-anchor status with **Update** (runs
   `unbound-anchor`) and **Reset to built-in**; QNAME minimisation;
   DNS-rebinding protection; IPv6 to upstream servers; blocked-name answer
   (NXDOMAIN or 0.0.0.0); log level; `custom.conf` editor; restore defaults.
5. **Safe apply**: settings are validated, written, Unbound is restarted; if it
   is not answering within 30 s the previous settings are restored, Unbound is
   restarted again and the error is shown.

## Non-goals / anti-goals

- No pattern (regex/substring) blocking.
- No per-domain forward zones in the UI (custom.conf covers them).
- Never leave the user with broken DNS after a settings change.
- Never let a value reach Unbound's config or the shell unvalidated.

## Design

- Storage: `settings.conf` gains keys `RESOLVER, CACHE_SIZE, CACHE_MIN_TTL,
  CACHE_MAX_TTL, PREFETCH, SERVE_EXPIRED, THREADS, DNSSEC, DNSSEC_PERMISSIVE,
  QNAME_MIN, REBIND_PROTECT, UPSTREAM_IPV6, BLOCK_ANSWER, LOG_LEVEL`. Custom
  forwarders live in `forwarders.list` (`addr[@port]#tlsname` per line). Own
  blocklist in `lists/block.list`.
- Generated `options.conf` (included after `runtime.conf`, before
  `custom.conf`) carries every setting plus a `forward-zone "."` with
  `forward-tls-upstream` when not recursive. `tls-cert-bundle` points at
  `/data/adb/unbound/ca.pem`, copied from Android's CA store at every start
  (inside the chroot; Unbound strips the chroot prefix).
- `do-ip6` = device has IPv6 AND `UPSTREAM_IPV6`.
- Blocklist merge gains tag `U` (own block) and a block type parameter
  (`always_nxdomain` / `always_null`).
- `ctl.sh`: `block-add/-remove`, `settings` (JSON), `settings-apply KEY=VALUE…`
  (all-or-nothing validation, apply with rollback; without a running daemon it
  only writes), `settings-reset`, `custom-get`, `custom-set <base64>`,
  `anchor-update`, `anchor-reset`.
- `unbound-anchor` is built and shipped (about 3 MB per ABI). It runs with a
  resolv.conf of `nameserver 127.0.0.1`, which the redirect sends to the
  running Unbound; its exit code does not distinguish errors, so its verbose
  output is checked.

## Calls made by the author

- Cache sizes: small 4/8/2 MB, medium 8/16/4 MB (default), large 32/64/8 MB
  (msg/rrset/key). Cache slabs follow the thread count (rounded to 1/2/4).
- Rebinding protection covers RFC 1918, CGNAT 100.64/10, link-local and ULA
  ranges.
- Revision bump to r4.
