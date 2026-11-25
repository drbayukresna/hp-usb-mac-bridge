#!/bin/sh
# Builds "HP Bridge.app" and a drag-to-install DMG in ./dist.
#
#   scripts/build-app.sh            # universal: Apple Silicon + Intel
#   SIGN_ID="Developer ID Application: …" scripts/build-app.sh
#                                   # sign with a Developer ID instead of ad-hoc
#
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
cd "$(dirname "$0")/.."

APP_NAME="HP Bridge"
BUNDLE_ID="io.github.drbayukresna.hpbridge"
VERSION="$(sed -n 's/^let version = "\(.*\)"/\1/p' Sources/hpbridge/main.swift)"
DIST="dist"
APP="$DIST/$APP_NAME.app"
SIGN_ID="${SIGN_ID:--}"

echo "==> Building HP Bridge $VERSION"
# A single multi-arch invocation needs full Xcode; building each slice on its
# own and joining them with lipo also works with the Command Line Tools.
# The product is "HPBridgeApp", not "HPBridge": on a case-insensitive disk the
# latter collides with the hpbridge CLI in the products folder.
BIN="$(mktemp -d)/HPBridgeApp"
ARCHS=""
# Slices are collected as positional parameters so paths with spaces survive.
set --
for arch in arm64 x86_64; do
    if swift build -c release --product HPBridgeApp --arch "$arch" >/dev/null 2>&1; then
        set -- "$@" "$(swift build -c release --arch "$arch" --show-bin-path)/HPBridgeApp"
        ARCHS="$ARCHS $arch"
    else
        echo "    warning: could not build the $arch slice"
    fi
done
[ "$#" -gt 0 ] || { echo "error: build failed"; swift build -c release --product HPBridgeApp; exit 1; }
lipo -create "$@" -output "$BIN"
echo "    architectures: $ARCHS"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HPBridge"
cp -R AppBundle/en.lproj AppBundle/id.lproj "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"

# Icon
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s AppBundle/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d AppBundle/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>HPBridge</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>id</string></array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>GPL-3.0-or-later · github.com/drbayukresna/hp-usb-mac-bridge</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Signing (${SIGN_ID})"
codesign --force --deep --options runtime --timestamp=none --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Creating DMG"
DMG="$DIST/HP-Bridge-$VERSION.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo
echo "App: $APP"
echo "DMG: $DMG ($(du -h "$DMG" | cut -f1))"
