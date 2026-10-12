#!/bin/bash
# Builds a release: universal Lectern Audio.app, ad-hoc signed, as a DMG (for people) and a ZIP plus appcast.xml (for Sparkle).
# Usage: scripts/release.sh <version> <build-number>     e.g. scripts/release.sh 0.2.0 7
# Env: SPARKLE_PRIVATE_KEY (EdDSA key; without it sign_update uses the login Keychain),
#      TAG (default v<version>), ARCHS (default "arm64 x86_64"),
#      LECTERN_FEED_URL and DOWNLOAD_URL_PREFIX (override for local update tests).
set -euo pipefail

version="${1:?version}"
build_number="${2:?build number}"
tag="${TAG:-v$version}"
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build/release"
app="$root/build/Build/Products/Release/Lectern Audio.app"
prefix="${DOWNLOAD_URL_PREFIX:-https://github.com/danihrndzld/LecternAudio/releases/download/$tag}"
sparkle_bin="$root/build/SourcePackages/artifacts/sparkle/Sparkle/bin"
cd "$root"

settings=(MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number"
    ARCHS="${ARCHS:-arm64 x86_64}" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO)
if [ -n "${LECTERN_FEED_URL:-}" ]; then settings+=(LECTERN_FEED_URL="$LECTERN_FEED_URL"); fi
xcodebuild -scheme LecternAudio -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath build "${settings[@]}" build | tail -3

# Sign inside out, no --deep (Sparkle's sandboxing guide). Sparkle rejects an update whose nested signatures are broken.
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
entitlements="$out/LecternAudio.entitlements"
rm -rf "$out" && mkdir -p "$out"
sed "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$bundle_id/g" App/LecternAudio.entitlements > "$entitlements"
sign() { codesign --force --sign - --options runtime --timestamp=none "$@"; }
sparkle="$app/Contents/Frameworks/Sparkle.framework"
sign "$sparkle/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
sign "$sparkle/Versions/B/Autoupdate"
sign "$sparkle/Versions/B/Updater.app"
sign "$sparkle"
sign --entitlements App/FFmpeg.entitlements "$app/Contents/Helpers/ffmpeg"
sign --entitlements App/Aria2.entitlements "$app/Contents/Helpers/aria2c"
sign --entitlements "$entitlements" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

name="LecternAudio-$version"
rm -rf "$out/dmg" "$out/$name.zip" "$out/$name.dmg"
ditto -c -k --keepParent "$app" "$out/$name.zip"
mkdir -p "$out/dmg"
ditto "$app" "$out/dmg/Lectern Audio.app"
ln -s /Applications "$out/dmg/Applications"
hdiutil create -volname "Lectern Audio" -srcfolder "$out/dmg" -fs HFS+ -format UDZO -ov "$out/$name.dmg" > /dev/null
rm -rf "$out/dmg"

if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    signature=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sparkle_bin/sign_update" --ed-key-file - "$out/$name.zip")
else
    signature=$("$sparkle_bin/sign_update" "$out/$name.zip")
fi

# Release notes: commit subjects since the previous tag.
ref=$(git rev-parse -q --verify "refs/tags/$tag" > /dev/null && echo "$tag" || echo HEAD)
previous=$(git describe --tags --abbrev=0 "$ref^" 2> /dev/null || true)
notes=$(git log --pretty='- %s' "${previous:+$previous..}$ref" | sed 's/]]>/]] >/g')

cat > "$out/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Lectern Audio</title>
    <item>
      <title>Lectern Audio $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build_number</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <description sparkle:format="plain-text"><![CDATA[$notes]]></description>
      <enclosure url="$prefix/$name.zip" type="application/octet-stream" $signature />
    </item>
  </channel>
</rss>
EOF
echo "$out/$name.dmg"
echo "$out/$name.zip"
echo "$out/appcast.xml"
