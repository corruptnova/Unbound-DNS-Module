#!/usr/bin/env bash
# Assemble the flashable module zip from module/ and out/<abi>/.
#
#   scripts/package.sh
#
# Output in dist/: unbound-dns-<version>.zip, update.json, changelog.md
# Env: GITHUB_REPOSITORY (owner/repo for update URLs), ABIS (default: all)
set -euo pipefail

. "$(dirname "$0")/lib.sh"
load_versions

REPO="${GITHUB_REPOSITORY:-corruptnova/Unbound-DNS-Module}"
VERSION="$(module_version)"
CODE="$(version_code "$UNBOUND_VERSION" "$MODULE_REVISION")"
DIST="$ROOT_DIR/dist"
STAGE="$ROOT_DIR/build/package"
ZIP="unbound-dns-$VERSION.zip"

rm -rf "$STAGE"
mkdir -p "$STAGE" "$DIST"
cp -R "$ROOT_DIR/module/." "$STAGE/"
rm -f "$STAGE/module.prop.in"
sed -e "s|@VERSION@|$VERSION|" -e "s|@VERSION_CODE@|$CODE|" \
    -e "s|@UNBOUND_VERSION@|$UNBOUND_VERSION|" -e "s|@REPO@|$REPO|" \
    "$ROOT_DIR/module/module.prop.in" > "$STAGE/module.prop"

licenses_done=0
for abi in $ABIS; do
    src="$ROOT_DIR/out/$abi"
    for f in unbound unbound-control unbound-anchor curl dropexec BUILDINFO; do
        [ -f "$src/$f" ] || die "missing $src/$f; run scripts/build.sh $abi first"
    done
    grep -q "^unbound=$UNBOUND_VERSION " "$src/BUILDINFO" \
        || die "out/$abi was built for another Unbound version than versions.env"
    mkdir -p "$STAGE/bin/$abi"
    cp "$src/unbound" "$src/unbound-control" "$src/unbound-anchor" "$src/curl" "$src/dropexec" \
        "$src/BUILDINFO" "$STAGE/bin/$abi/"
    for f in unbound unbound-control unbound-anchor curl dropexec; do chmod 0755 "$STAGE/bin/$abi/$f"; done
    if [ "$licenses_done" = 0 ] && [ -d "$src/licenses" ]; then
        mkdir -p "$STAGE/licenses"
        cp "$src"/licenses/* "$STAGE/licenses/"
        licenses_done=1
    fi
done
cp "$ROOT_DIR/LICENSE" "$STAGE/licenses/unbound-dns-module.txt"

rm -f "$DIST/$ZIP"
(cd "$STAGE" && zip -qr9 -X "$DIST/$ZIP" .)

cat > "$DIST/update.json" <<EOF
{
  "version": "$VERSION",
  "versionCode": $CODE,
  "zipUrl": "https://github.com/$REPO/releases/download/$VERSION/$ZIP",
  "changelog": "https://github.com/$REPO/releases/download/$VERSION/changelog.md"
}
EOF

cat > "$DIST/changelog.md" <<EOF
## $VERSION

- Unbound $UNBOUND_VERSION ([release notes](https://nlnetlabs.nl/projects/unbound/download/))
- OpenSSL $OPENSSL_VERSION, expat $EXPAT_VERSION, curl $CURL_VERSION
- Built with Android NDK $NDK_VERSION for API $ANDROID_API+ ($(echo "$ABIS" | tr ' ' ','))
EOF
if [ -f "$ROOT_DIR/CHANGELOG.md" ]; then
    # Notes for this revision, if the maintainer wrote any.
    awk -v v="## $VERSION" '$0 == v { on = 1; next } /^## / { on = 0 } on' \
        "$ROOT_DIR/CHANGELOG.md" >> "$DIST/changelog.md"
fi

log "packaged dist/$ZIP ($(du -h "$DIST/$ZIP" | cut -f1)), versionCode $CODE"
