#!/bin/bash
# Builds aria2c (GPLv2+ with the OpenSSL exception) as a separate helper executable: HTTP(S) only, TLS from
# the system (AppleTLS), no third-party libraries, so it links only against macOS system libraries.
set -euo pipefail

project_root="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cache="$project_root/build/aria2-1.37.0"
archive="$cache/aria2-1.37.0.tar.xz"
source_dir="$cache/aria2-1.37.0"
source_sha=60a420ad7085eb616cb6e2bdf0a7206d68ff3d37fb5a956dc44242eb2f79b66b
architectures="${ARCHS:-$(uname -m)}"
deployment_target="${MACOSX_DEPLOYMENT_TARGET:-26.0}"
script_sha=$(shasum -a 256 "$0" | cut -d ' ' -f 1)
mkdir -p "$cache"
if [ ! -f "$archive" ]; then
    curl --fail --location --retry 3 https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0.tar.xz -o "$archive.download"
    mv "$archive.download" "$archive"
fi
printf '%s  %s\n' "$source_sha" "$archive" | shasum -a 256 --check --status
if [ ! -d "$source_dir" ]; then tar -xf "$archive" -C "$cache"; fi

binaries=()
for architecture in $architectures; do
    case "$architecture" in arm64) host=aarch64-apple-darwin ;; x86_64) host=x86_64-apple-darwin ;;
        *) echo "Unsupported aria2 architecture: $architecture" >&2; exit 1 ;; esac
    build_dir="$cache/$architecture"
    stamp="$script_sha-$deployment_target"
    if [ ! -x "$build_dir/src/aria2c" ] || [ "$(cat "$build_dir/lectern-build-id" 2>/dev/null || true)" != "$stamp" ]; then
        rm -rf "$build_dir" && mkdir -p "$build_dir"
        (
            cd "$build_dir"
            sdk="$(xcrun --sdk macosx --show-sdk-path)"
            flags="-arch $architecture -isysroot $sdk -mmacosx-version-min=$deployment_target -O2"
            # Clear Xcode's build environment so configure only sees the SDK, never Homebrew or MacPorts.
            env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" \
                CC="$(xcrun --find clang)" CXX="$(xcrun --find clang++)" CFLAGS="$flags" CXXFLAGS="$flags" LDFLAGS="$flags" \
                PKG_CONFIG=/usr/bin/false PKG_CONFIG_LIBDIR=/nonexistent \
                "$source_dir/configure" --host="$host" --build="$(uname -m | sed s/arm64/aarch64/)-apple-darwin" \
                --disable-dependency-tracking --disable-silent-rules --disable-nls --disable-shared --enable-static \
                --with-appletls --without-gnutls --without-openssl --without-libnettle --without-libgmp \
                --without-libgcrypt --without-sqlite3 --without-libxml2 --without-libexpat --without-libcares \
                --without-libz --without-libssh2 --without-libuv \
                --disable-bittorrent --disable-metalink --disable-websocket > configure.log 2>&1
            env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" make -j "$(sysctl -n hw.ncpu)" -C src aria2c > build.log 2>&1
            xcrun strip -x src/aria2c
            printf '%s' "$stamp" > lectern-build-id
        )
    fi
    binaries+=("$build_dir/src/aria2c")
done

if [ -n "${TARGET_BUILD_DIR:-}" ]; then
    helper_dir="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
    license_dir="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/aria2"
else
    helper_dir="$cache/bin"
    license_dir="$cache/distribution"
fi
mkdir -p "$helper_dir" "$license_dir"
xcrun lipo -create "${binaries[@]}" -output "$helper_dir/aria2c"
cp "$archive" "$license_dir/aria2-1.37.0.tar.xz"
cp "$source_dir/COPYING" "$license_dir/COPYING"
cp "$source_dir/LICENSE.OpenSSL" "$license_dir/LICENSE.OpenSSL"
cp "$0" "$license_dir/build-aria2.sh"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]; then
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
        --entitlements "$project_root/App/Aria2.entitlements" --timestamp=none "$helper_dir/aria2c"
fi
