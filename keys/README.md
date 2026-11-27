# Release signing keys

Every source tarball is checked against its project's release signature
before its sha256 is pinned (`scripts/update-versions.sh`) and again at
every build (`scripts/build.sh`). Only the key in this folder is accepted
for each project; a release signed with any other key stops the update.

| File          | Project | Primary key fingerprint                    | Owner                                   |
|---------------|---------|--------------------------------------------|-----------------------------------------|
| `unbound.asc` | Unbound | `2310 1869 0C4D 903E F419 146A A144 323D EAAC DF45` | NLnet Labs releases signing key G2 |
| `openssl.asc` | OpenSSL | `B146 647E 45A7 B339 47AB 226B 2A2C 87D1 6169 2D40` | OpenSSL `<openssl@openssl.org>`  |
| `expat.asc`   | expat   | `3176 EF7D B236 7F1F CA4F 306B 1F9B 0E90 9AF3 7285` | Sebastian Pipping (maintainer)   |
| `curl.asc`    | curl    | `27ED EAF2 2F3A BCEB 50DB 9A12 5CC9 08FD B71E 12C2` | Daniel Stenberg (maintainer)     |

Where the fingerprints were checked (November 2026):

- **Unbound:** keyserver.ubuntu.com and `https://nlnetlabs.nl/downloads/keys/releases-g2.asc`.
- **OpenSSL:** keyserver.ubuntu.com and `doc/fingerprints.txt` in the OpenSSL
  repository (master and openssl-3.5). Releases are signed with a subkey.
- **expat, curl:** keyserver.ubuntu.com; the fingerprints are the ones these
  maintainers have used for years. Their own sites could not be reached
  when the keys were added. Both sign with a subkey.

All four verify the releases pinned at the time (Unbound 1.26.2,
OpenSSL 3.5.9, expat 2.11.0, curl 8.23.0).

## When a project changes keys

The scheduled update fails with "bad or missing signature". Check the new
fingerprint against the project's own announcement, then replace the file:

    gpg --armor --export --export-options export-minimal FINGERPRINT > keys/NAME.asc

and update the table above.
