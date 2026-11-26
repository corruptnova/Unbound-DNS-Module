# Changelog

Notes for module revisions. Releases list the bundled versions on top of
these notes.

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
