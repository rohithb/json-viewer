#!/bin/sh
# Builds "JSON Viewer.app" into ./build with plain swiftc (no Xcode or SwiftPM needed).
#   ./build.sh           dev build for this Mac's architecture
#   ./build.sh release   universal (arm64 + x86_64), hardened runtime, plus dist/JSON-Viewer-<version>.dmg
set -e
cd "$(dirname "$0")"
MODE=${1:-dev}
APP="build/JSON Viewer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

case "$MODE" in
  dev)     ARCHS=$(uname -m) ;;
  release) ARCHS="arm64 x86_64" ;;
  *)       echo "usage: $0 [release]" >&2; exit 1 ;;
esac

# Some Command Line Tools installs ship both module.modulemap and bridging.modulemap defining
# SwiftBridging, which breaks `import Foundation`. Hide the duplicate with a VFS overlay.
FLAGS=""
DUP=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
if [ -f "$DUP" ] && [ -f "$(dirname "$DUP")/bridging.modulemap" ]; then
  : > build/empty.modulemap
  printf '{"version":0,"case-sensitive":"false","roots":[{"type":"file","name":"%s","external-contents":"%s"}]}' \
    "$DUP" "$PWD/build/empty.modulemap" > build/vfs.yaml
  FLAGS="-vfsoverlay build/vfs.yaml -Xcc -ivfsoverlay -Xcc build/vfs.yaml"
fi

# Embed jq (official static release binary, checksum-verified) so the app needs no installed jq.
JQ_VERSION=1.8.2
fetch_jq() { # $1 = arm64 | x86_64; prints the cached path
  case "$1" in
    arm64)  a=arm64; sha=2d75340ba57a4b4b4c8708a21c2dc8e958a48aaa8bba13b27f77f6e4c0eca07e ;;
    x86_64) a=amd64; sha=e94b266e3c26690550006abe63152b782280f4e14374accdf04cbde844f00bc0 ;;
  esac
  f="build/jq-$JQ_VERSION-$a"
  if [ ! -f "$f" ]; then
    curl -fsSL -o "$f.tmp" "https://github.com/jqlang/jq/releases/download/jq-$JQ_VERSION/jq-macos-$a"
    echo "$sha  $f.tmp" | shasum -a 256 -c - >/dev/null
    mv "$f.tmp" "$f"
  fi
  echo "$f"
}

BINS="" JQS=""
for arch in $ARCHS; do
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macosx14.0" $FLAGS \
    Sources/JSONViewer/*.swift -o "build/JSONViewer-$arch"
  BINS="$BINS build/JSONViewer-$arch"
  JQS="$JQS $(fetch_jq "$arch")"
done
lipo -create $BINS -output "$APP/Contents/MacOS/JSONViewer"
lipo -create $JQS -output "$APP/Contents/Resources/jq"
chmod +x "$APP/Contents/Resources/jq"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"  # regenerate: see scripts/make-icon.swift

# Sign with a stable identity when available so Keychain "Always Allow" survives rebuilds;
# ad-hoc signatures change every build and make macOS re-prompt for each saved key.
IDENTITY=-
security find-identity -p codesigning | grep -q '"JSON Viewer Dev"' && IDENTITY="JSON Viewer Dev"
if [ "$MODE" = release ]; then
  # Hardened runtime on every executable (required for notarization).
  codesign -s "$IDENTITY" --force --options runtime "$APP/Contents/Resources/jq"
  codesign -s "$IDENTITY" --force --options runtime "$APP"
else
  codesign -s "$IDENTITY" --force --deep "$APP"
fi
echo "Built $APP ($ARCHS, signed: $IDENTITY)"

if [ "$MODE" = release ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
  DMG="dist/JSON-Viewer-$VERSION.dmg"
  STAGE=build/dmg
  rm -rf "$STAGE" "$DMG" && mkdir -p "$STAGE" dist
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "JSON Viewer" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  codesign -s "$IDENTITY" --force "$DMG"
  echo "Packaged $DMG"
fi
