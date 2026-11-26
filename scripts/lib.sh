#!/usr/bin/env bash
# Shared helpers for the host-side build scripts (bash, Linux).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="${CACHE_DIR:-$ROOT_DIR/.cache}"
ABIS="arm64-v8a armeabi-v7a x86_64"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Load versions.env without overriding variables already set in the
# environment (lets CI or a developer try another version).
load_versions() {
    local line key
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        key="${line%%=*}"
        # shellcheck disable=SC2163  # exports NAME=value from the file
        [ -n "${!key+x}" ] || export "$line"
    done < "$ROOT_DIR/versions.env"
}

# fetch_verified URL SHA256 DEST
# Downloads URL to DEST unless DEST already has the right hash.
fetch_verified() {
    local url="$1" sha="$2" dest="$3"
    [ -n "$sha" ] || die "no sha256 pinned for $(basename "$dest"); run scripts/update-versions.sh"
    if [ -f "$dest" ] && echo "$sha  $dest" | sha256sum -c --status; then
        return 0
    fi
    mkdir -p "$(dirname "$dest")"
    log "downloading $url"
    curl -fsSL --retry 3 --retry-delay 5 -o "$dest.part" "$url" || die "download failed: $url"
    echo "$sha  $dest.part" | sha256sum -c --status \
        || die "sha256 mismatch for $url (expected $sha, got $(sha256sum "$dest.part" | cut -d' ' -f1))"
    mv "$dest.part" "$dest"
}

# abi_triple ABI -> clang target triple prefix (without API level)
abi_triple() {
    case "$1" in
        arm64-v8a)   echo aarch64-linux-android ;;
        armeabi-v7a) echo armv7a-linux-androideabi ;;
        x86_64)      echo x86_64-linux-android ;;
        *) die "unsupported ABI: $1" ;;
    esac
}

# autoconf --host value (config.sub does not know armv7a-...-androideabi)
abi_host() {
    case "$1" in
        arm64-v8a)   echo aarch64-linux-android ;;
        armeabi-v7a) echo arm-linux-androideabi ;;
        x86_64)      echo x86_64-linux-android ;;
        *) die "unsupported ABI: $1" ;;
    esac
}

abi_openssl_target() {
    case "$1" in
        arm64-v8a)   echo android-arm64 ;;
        armeabi-v7a) echo android-arm ;;
        x86_64)      echo android-x86_64 ;;
        *) die "unsupported ABI: $1" ;;
    esac
}

# version_code 1.26.2 3 -> 1260203
version_code() {
    local major minor patch
    IFS=. read -r major minor patch <<EOF
$1
EOF
    echo $(( major * 1000000 + minor * 10000 + ${patch:-0} * 100 + $2 ))
}

module_version() { echo "v${UNBOUND_VERSION}-r${MODULE_REVISION}"; }
