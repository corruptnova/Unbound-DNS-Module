#!/usr/bin/env bash
# Cross-compile Unbound (+ OpenSSL, expat, curl) for one Android ABI.
#
#   scripts/build.sh <arm64-v8a|armeabi-v7a|x86_64|all>
#
# Output: out/<abi>/{unbound,unbound-control,unbound-anchor,curl}
#
# Environment:
#   ANDROID_NDK_HOME   NDK to use if it is the pinned version (otherwise the
#                      pinned NDK is downloaded into .cache)
#   JOBS               parallel make jobs (default: nproc)
#   <NAME>_SRC_DIR     use an already-extracted source tree for NAME
#                      (OPENSSL, EXPAT, UNBOUND, CURL) instead of the pinned
#                      tarball. For local experiments only; CI never sets it.
set -euo pipefail

. "$(dirname "$0")/lib.sh"
load_versions

JOBS="${JOBS:-$(nproc)}"

ensure_ndk() {
    local ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
    if [ -n "$ndk" ] && [ -d "$ndk/toolchains/llvm" ]; then
        local rel
        rel="$(sed -n 's/^Pkg.ReleaseName *= *//p' "$ndk/source.properties" 2>/dev/null || true)"
        if [ "$rel" = "$NDK_VERSION" ]; then
            NDK="$ndk"
            return
        fi
        log "NDK at $ndk is ${rel:-unknown}; versions.env pins $NDK_VERSION, fetching that"
    fi
    NDK="$CACHE_DIR/android-ndk-$NDK_VERSION"
    if [ ! -d "$NDK/toolchains/llvm" ]; then
        local zip="$CACHE_DIR/android-ndk-$NDK_VERSION-linux.zip"
        mkdir -p "$CACHE_DIR"
        log "downloading NDK $NDK_VERSION"
        curl -fsSL --retry 3 -o "$zip.part" \
            "https://dl.google.com/android/repository/android-ndk-$NDK_VERSION-linux.zip"
        echo "$NDK_SHA1  $zip.part" | sha1sum -c --status || die "NDK sha1 mismatch"
        mv "$zip.part" "$zip"
        (cd "$CACHE_DIR" && unzip -q "$zip") && rm -f "$zip"
    fi
}

# prepare_src NAME TARBALL_URL SHA256 -> echoes source dir
prepare_src() {
    local name="$1" url="$2" sha="$3"
    local override_var="${name^^}_SRC_DIR"
    local dir="$BUILD/src/$name"
    if [ -n "${!override_var:-}" ]; then
        log "using local $name source from ${!override_var}"
        rm -rf "$dir"; mkdir -p "$dir"
        cp -a "${!override_var}/." "$dir/"
    else
        local tarball
        tarball="$CACHE_DIR/src/$(basename "$url")"
        fetch_verified "$url" "$sha" "$tarball"
        rm -rf "$dir"; mkdir -p "$dir"
        tar -xf "$tarball" -C "$dir" --strip-components=1
    fi
    echo "$dir"
}

setup_toolchain() {
    TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
    local triple; triple="$(abi_triple "$ABI")"
    export CC="$TOOLCHAIN/bin/${triple}${ANDROID_API}-clang"
    export CXX="$TOOLCHAIN/bin/${triple}${ANDROID_API}-clang++"
    export AR="$TOOLCHAIN/bin/llvm-ar"
    export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
    export NM="$TOOLCHAIN/bin/llvm-nm"
    export STRIP="$TOOLCHAIN/bin/llvm-strip"
    export CFLAGS="-O2 -fPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2 -ffunction-sections -fdata-sections"
    # 16 KB page alignment for Android 15+ devices; full RELRO; drop unused code.
    export LDFLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,relro -Wl,-z,now -Wl,--gc-sections"
    [ -x "$CC" ] || die "compiler not found: $CC"
}

# Algorithms and protocols neither DNSSEC validation nor an HTTPS download
# needs. Keeps each statically linked binary small.
OPENSSL_TRIM="no-legacy no-idea no-camellia no-seed no-bf no-cast no-des no-rc2 no-rc4 \
    no-rc5 no-md4 no-mdc2 no-whirlpool no-sm2 no-sm3 no-sm4 no-aria no-siphash no-srp \
    no-ssl3 no-dtls no-srtp no-sctp no-quic no-ct no-cms no-ts no-ocb no-ec2m \
    no-slh-dsa no-ml-dsa no-argon2 no-scrypt no-gost no-dsa"

build_openssl() {
    [ -f "$DEPS/.openssl-$OPENSSL_VERSION" ] && return
    local src
    src="$(prepare_src openssl \
        "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
        "$OPENSSL_SHA256")"
    log "[$ABI] building OpenSSL $OPENSSL_VERSION"
    (
        cd "$src"
        # OpenSSL's android targets pick clang from PATH and add --target
        # themselves, so hide our CC/AR. OPENSSL_TRIM is a list of options.
        # shellcheck disable=SC2086
        env -u CC -u CXX -u AR -u RANLIB -u NM -u STRIP -u CFLAGS -u LDFLAGS \
            ANDROID_NDK_ROOT="$NDK" PATH="$TOOLCHAIN/bin:$PATH" \
            ./Configure "$(abi_openssl_target "$ABI")" -D__ANDROID_API__="$ANDROID_API" \
                --prefix="$DEPS" --libdir=lib \
                no-shared no-tests no-docs no-apps no-engine no-module no-comp \
                no-ui-console $OPENSSL_TRIM \
                -fPIC -O2 -ffunction-sections -fdata-sections \
                >"$BUILD/openssl-configure.log" 2>&1 \
            || { tail -30 "$BUILD/openssl-configure.log"; die "OpenSSL configure failed"; }
        env -u CC -u CXX -u AR -u RANLIB -u NM -u STRIP -u CFLAGS -u LDFLAGS \
            ANDROID_NDK_ROOT="$NDK" PATH="$TOOLCHAIN/bin:$PATH" \
            make -j"$JOBS" build_libs >"$BUILD/openssl-build.log" 2>&1 \
            || { tail -30 "$BUILD/openssl-build.log"; die "OpenSSL build failed"; }
        env -u CC -u CXX -u AR -u RANLIB -u NM -u STRIP -u CFLAGS -u LDFLAGS \
            ANDROID_NDK_ROOT="$NDK" PATH="$TOOLCHAIN/bin:$PATH" \
            make install_dev >>"$BUILD/openssl-build.log" 2>&1 \
            || { tail -30 "$BUILD/openssl-build.log"; die "OpenSSL install failed"; }
    )
    touch "$DEPS/.openssl-$OPENSSL_VERSION"
}

build_expat() {
    [ -f "$DEPS/.expat-$EXPAT_VERSION" ] && return
    local src
    src="$(prepare_src expat \
        "https://github.com/libexpat/libexpat/releases/download/R_${EXPAT_VERSION//./_}/expat-$EXPAT_VERSION.tar.xz" \
        "$EXPAT_SHA256")"
    # Release tarballs have CMakeLists.txt at the top; the git tree has it in expat/.
    [ -f "$src/CMakeLists.txt" ] || src="$src/expat"
    log "[$ABI] building expat $EXPAT_VERSION"
    cmake -S "$src" -B "$BUILD/expat-build" \
        -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="$ABI" -DANDROID_PLATFORM="android-$ANDROID_API" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$DEPS" -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DEXPAT_SHARED_LIBS=OFF -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_EXAMPLES=OFF \
        -DEXPAT_BUILD_TESTS=OFF -DEXPAT_BUILD_DOCS=OFF -DEXPAT_BUILD_FUZZERS=OFF \
        >"$BUILD/expat.log" 2>&1 || { tail -30 "$BUILD/expat.log"; die "expat configure failed"; }
    cmake --build "$BUILD/expat-build" -j"$JOBS" >>"$BUILD/expat.log" 2>&1 \
        && cmake --install "$BUILD/expat-build" >>"$BUILD/expat.log" 2>&1 \
        || { tail -30 "$BUILD/expat.log"; die "expat build failed"; }
    touch "$DEPS/.expat-$EXPAT_VERSION"
}

build_unbound() {
    local src
    src="$(prepare_src unbound \
        "https://nlnetlabs.nl/downloads/unbound/unbound-$UNBOUND_VERSION.tar.gz" \
        "$UNBOUND_SHA256")"
    log "[$ABI] building Unbound $UNBOUND_VERSION"
    (
        cd "$src"
        ./configure --host="$(abi_host "$ABI")" --prefix=/ \
            --with-conf-file=/data/adb/unbound/unbound.conf \
            --with-run-dir=/data/adb/unbound \
            --with-chroot-dir=/data/adb/unbound \
            --with-rootkey-file=/data/adb/unbound/var/root.key \
            --with-pidfile= \
            --with-username=inet \
            --with-ssl="$DEPS" --with-libexpat="$DEPS" \
            --disable-shared --enable-static --disable-rpath --disable-flto \
            --disable-gost --without-pythonmodule --without-pyunbound \
            --with-pthreads \
            >"$BUILD/unbound-configure.log" 2>&1 \
            || { tail -40 "$BUILD/unbound-configure.log"; die "Unbound configure failed"; }
        make -j"$JOBS" unbound unbound-control unbound-anchor >"$BUILD/unbound-build.log" 2>&1 \
            || { tail -40 "$BUILD/unbound-build.log"; die "Unbound build failed"; }
        install -m 0755 unbound unbound-control unbound-anchor "$OUT/"
    )
}

build_curl() {
    local src
    src="$(prepare_src curl "https://curl.se/download/curl-$CURL_VERSION.tar.xz" "$CURL_SHA256")"
    log "[$ABI] building curl $CURL_VERSION"
    (
        cd "$src"
        # HTTPS-only client for blocklist downloads. The CA bundle is passed
        # at runtime (built from Android's system store).
        ./configure --host="$(abi_host "$ABI")" --prefix=/ \
            --with-openssl="$DEPS" --disable-shared --enable-static \
            --without-ca-bundle --without-ca-path --without-ca-fallback \
            --without-libpsl --without-zlib --without-brotli --without-zstd \
            --without-libidn2 --without-nghttp2 --without-nghttp3 --without-ngtcp2 \
            --without-libssh2 --without-librtmp \
            --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet \
            --disable-tftp --disable-pop3 --disable-imap --disable-smb --disable-smtp \
            --disable-gopher --disable-mqtt --disable-ftp --disable-file --disable-ipfs \
            --disable-websockets --disable-ntlm --disable-docs --disable-manual \
            >"$BUILD/curl-configure.log" 2>&1 \
            || { tail -40 "$BUILD/curl-configure.log"; die "curl configure failed"; }
        make -j"$JOBS" >"$BUILD/curl-build.log" 2>&1 \
            || { tail -40 "$BUILD/curl-build.log"; die "curl build failed"; }
        install -m 0755 src/curl "$OUT/curl"
    )
}

build_abi() {
    ABI="$1"
    BUILD="$ROOT_DIR/build/$ABI"
    DEPS="$BUILD/deps"
    OUT="$ROOT_DIR/out/$ABI"
    mkdir -p "$BUILD" "$DEPS" "$OUT"
    setup_toolchain
    build_openssl
    build_expat
    build_unbound
    build_curl
    "$STRIP" --strip-unneeded "$OUT/unbound" "$OUT/unbound-control" "$OUT/unbound-anchor" "$OUT/curl"
    mkdir -p "$OUT/licenses"
    cp "$BUILD/src/unbound/LICENSE" "$OUT/licenses/unbound.txt"
    cp "$BUILD/src/openssl/LICENSE.txt" "$OUT/licenses/openssl.txt"
    cp "$BUILD/src/curl/COPYING" "$OUT/licenses/curl.txt"
    if [ -f "$BUILD/src/expat/COPYING" ]; then
        cp "$BUILD/src/expat/COPYING" "$OUT/licenses/expat.txt"
    else
        cp "$BUILD/src/expat/expat/COPYING" "$OUT/licenses/expat.txt"
    fi
    {
        echo "abi=$ABI"
        echo "ndk=$NDK_VERSION api=$ANDROID_API"
        echo "unbound=$UNBOUND_VERSION openssl=$OPENSSL_VERSION expat=$EXPAT_VERSION curl=$CURL_VERSION"
    } > "$OUT/BUILDINFO"
    log "[$ABI] done: $(cd "$OUT" && du -ch unbound unbound-control unbound-anchor curl | tail -1)"
}

[ $# -eq 1 ] || die "usage: $0 <arm64-v8a|armeabi-v7a|x86_64|all>"
ensure_ndk
if [ "$1" = all ]; then
    for abi in $ABIS; do build_abi "$abi"; done
else
    build_abi "$1"
fi
