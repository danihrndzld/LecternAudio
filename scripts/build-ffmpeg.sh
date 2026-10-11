#!/bin/bash
set -euo pipefail

project_root="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cache="$project_root/build/ffmpeg-8.0"
archive="$cache/ffmpeg-8.0.tar.xz"
source_dir="$cache/ffmpeg-8.0"
source_sha=b2751fccb6cc4c77708113cd78b561059b6fa904b24162fa0be2d60273d27b8e
architectures="${ARCHS:-$(uname -m)}"
deployment_target="${MACOSX_DEPLOYMENT_TARGET:-26.0}"
script_sha=$(shasum -a 256 "$0" | cut -d ' ' -f 1)
mkdir -p "$cache"
if [ ! -f "$archive" ]; then
    curl --fail --location --retry 3 https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz -o "$archive.download"
    mv "$archive.download" "$archive"
fi
printf '%s  %s\n' "$source_sha" "$archive" | shasum -a 256 --check --status
if [ ! -d "$source_dir" ]; then tar -xf "$archive" -C "$cache"; fi

binaries=()
for architecture in $architectures; do
    case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported FFmpeg architecture: $architecture" >&2; exit 1 ;; esac
    build_dir="$cache/$architecture"
    stamp="$script_sha-$deployment_target"
    if [ ! -x "$build_dir/ffmpeg" ] || [ "$(cat "$build_dir/earmark-build-id" 2>/dev/null || true)" != "$stamp" ]; then
        mkdir -p "$build_dir"
        (
            cd "$build_dir"
            "$source_dir/configure" --cc="$(xcrun --find clang)" --arch="$architecture" --target-os=darwin \
                --sysroot="$(xcrun --sdk macosx --show-sdk-path)" \
                --enable-cross-compile --extra-cflags="-arch $architecture -mmacosx-version-min=$deployment_target" \
                --extra-ldflags="-arch $architecture -mmacosx-version-min=$deployment_target" \
                --disable-autodetect --disable-everything --disable-doc --disable-debug --disable-network \
                --disable-shared --enable-static --disable-x86asm --disable-avdevice --disable-swscale \
                --disable-ffplay --disable-ffprobe --enable-ffmpeg --enable-zlib \
                --enable-protocol=file,pipe --enable-demuxer=mov,ffmetadata,image2 \
                --enable-muxer=mp4,null,ffmetadata --enable-decoder=aac,png,mjpeg \
                --enable-encoder=pcm_s16le --enable-parser=aac,png,mjpeg \
                --enable-filter=aformat,anull,aresample --enable-bsf=aac_adtstoasc > configure.log 2>&1
            make -j "$(sysctl -n hw.ncpu)" ffmpeg > build.log 2>&1
            printf '%s' "$stamp" > earmark-build-id
        )
    fi
    binaries+=("$build_dir/ffmpeg")
done

if [ -n "${TARGET_BUILD_DIR:-}" ]; then
    helper_dir="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
    license_dir="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/FFmpeg"
else
    helper_dir="$cache/bin"
    license_dir="$cache/distribution"
fi
mkdir -p "$helper_dir" "$license_dir"
xcrun lipo -create "${binaries[@]}" -output "$helper_dir/ffmpeg"
cp "$archive" "$license_dir/ffmpeg-8.0.tar.xz"
cp "$source_dir/COPYING.LGPLv2.1" "$license_dir/COPYING.LGPLv2.1"
cp "$0" "$license_dir/build-ffmpeg.sh"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]; then
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
        --entitlements "$project_root/App/FFmpeg.entitlements" --timestamp=none "$helper_dir/ffmpeg"
fi
