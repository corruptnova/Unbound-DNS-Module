#!/usr/bin/env bash
# Pin the newest upstream releases in versions.env.
#
#   scripts/update-versions.sh            bump to the latest releases
#   scripts/update-versions.sh --fill     keep versions, only pin missing sha256
#   scripts/update-versions.sh --check    print latest versions, change nothing
#
# Versions are discovered with `git ls-remote` (no API rate limits). Before a
# tarball's sha256 is pinned, its release signature must verify against the
# project's key in keys/ (only that key); builds check both again.
#
# Revision rule: a new Unbound resets MODULE_REVISION to 1; a dependency-only
# update increments it.
#
# Prints a summary; with GITHUB_OUTPUT set also writes changed=, version=
# and summary= there.
set -euo pipefail

. "$(dirname "$0")/lib.sh"
FILE="$ROOT_DIR/versions.env"
MODE="${1:-bump}"
case "$MODE" in bump|--fill|--check) ;; *) die "usage: $0 [--fill|--check]" ;; esac

get() { sed -n "s/^$1=//p" "$FILE"; }
put() {
    if grep -q "^$1=" "$FILE"; then sed -i "s|^$1=.*|$1=$2|" "$FILE"; else echo "$1=$2" >> "$FILE"; fi
}

# latest TAGS_URL SED_EXPR -> highest version among matching tags
latest() {
    git ls-remote --tags --refs "$1" | sed -n "$2" | sort -V | tail -n 1
}

latest_unbound() { latest https://github.com/NLnetLabs/unbound 's|.*refs/tags/release-\([0-9]*\.[0-9]*\.[0-9]*\)$|\1|p'; }
latest_openssl() {
    local series; series="$(get OPENSSL_SERIES)"
    latest https://github.com/openssl/openssl "s|.*refs/tags/openssl-\(${series//./\\.}\.[0-9]*\)$|\1|p"
}
latest_expat() { latest https://github.com/libexpat/libexpat 's|.*refs/tags/R_\([0-9]*\)_\([0-9]*\)_\([0-9]*\)$|\1.\2.\3|p'; }
latest_curl() { latest https://github.com/curl/curl 's|.*refs/tags/curl-\([0-9]*\)_\([0-9]*\)_\([0-9]*\)$|\1.\2.\3|p'; }

tarball_url() {
    case "$1" in
        UNBOUND) echo "https://nlnetlabs.nl/downloads/unbound/unbound-$2.tar.gz" ;;
        OPENSSL) echo "https://github.com/openssl/openssl/releases/download/openssl-$2/openssl-$2.tar.gz" ;;
        EXPAT)   echo "https://github.com/libexpat/libexpat/releases/download/R_${2//./_}/expat-$2.tar.xz" ;;
        CURL)    echo "https://curl.se/download/curl-$2.tar.xz" ;;
    esac
}

# sha_for NAME VERSION -> sha256 of the release tarball, once its signature
# checks out against keys/<name>.asc
sha_for() {
    local name="$1" ver="$2" url tmp sha
    url="$(tarball_url "$name" "$ver")"
    tmp="$(mktemp -d)"
    curl -fsSL --retry 3 -o "$tmp/src" "$url" || { rm -rf "$tmp"; die "cannot download $url"; }
    curl -fsSL --retry 3 -o "$tmp/src.asc" "$url.asc" || { rm -rf "$tmp"; die "cannot download $url.asc"; }
    verify_signature "${name,,}" "$tmp/src" "$tmp/src.asc"
    sha="$(sha256sum "$tmp/src" | cut -d' ' -f1)"
    rm -rf "$tmp"
    echo "$sha"
}

declare -A NEW
NEW[UNBOUND]="$(latest_unbound)"
NEW[OPENSSL]="$(latest_openssl)"
NEW[EXPAT]="$(latest_expat)"
NEW[CURL]="$(latest_curl)"
for n in UNBOUND OPENSSL EXPAT CURL; do
    [ -n "${NEW[$n]}" ] || die "could not determine the latest $n version"
done

if [ "$MODE" = --check ]; then
    for n in UNBOUND OPENSSL EXPAT CURL; do
        printf '%-8s pinned %-8s latest %s\n' "$n" "$(get "${n}_VERSION")" "${NEW[$n]}"
    done
    exit 0
fi

before="$(cat "$FILE")"
summary=()
unbound_changed=0
deps_changed=0
for n in UNBOUND OPENSSL EXPAT CURL; do
    old="$(get "${n}_VERSION")"
    new="${NEW[$n]}"
    [ "$MODE" = --fill ] && new="$old"
    if [ "$new" != "$old" ]; then
        log "$n $old -> $new"
        put "${n}_SHA256" "$(sha_for "$n" "$new")"
        put "${n}_VERSION" "$new"
        summary+=("$n $old -> $new")
        if [ "$n" = UNBOUND ]; then unbound_changed=1; else deps_changed=1; fi
    elif [ -z "$(get "${n}_SHA256")" ]; then
        log "$n $old: pinning sha256"
        put "${n}_SHA256" "$(sha_for "$n" "$old")"
        summary+=("pin $n $old sha256")
    fi
done

if [ "$unbound_changed" = 1 ]; then
    put MODULE_REVISION 1
elif [ "$deps_changed" = 1 ]; then
    put MODULE_REVISION $(( $(get MODULE_REVISION) + 1 ))
fi

changed=false
[ "$before" = "$(cat "$FILE")" ] || changed=true
version="v$(get UNBOUND_VERSION)-r$(get MODULE_REVISION)"
text="$(IFS=', '; echo "${summary[*]:-no changes}")"
echo "changed=$changed version=$version: $text"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "changed=$changed"
        echo "version=$version"
        echo "summary=$text"
    } >> "$GITHUB_OUTPUT"
fi
