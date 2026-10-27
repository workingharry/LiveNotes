#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

echo "🔨 Building release binary via Swift Package Manager..."
swift build -c release

BIN_PATH="$DIR/.build/release/LiveNotes"

if [ ! -f "$BIN_PATH" ]; then
    echo "❌ Error: Build binary not found at $BIN_PATH"
    exit 1
fi

echo "📦 Assembling LiveNotes.app bundle..."
APP_DIR="$DIR/LiveNotes.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/LiveNotes"
chmod +x "$APP_DIR/Contents/MacOS/LiveNotes"
cp "$DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
echo "APPL????" > "$APP_DIR/Contents/PkgInfo"

echo "🔏 Code signing LiveNotes.app with entitlements..."
codesign -s - -f --deep --entitlements "$DIR/LiveNotes.entitlements" "$APP_DIR"

echo "💿 Creating DMG installer..."
DMG_STAGING="$DIR/dmg_staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"

# Copy App to staging
cp -R "$APP_DIR" "$DMG_STAGING/"

# Add Applications symlink
ln -s /Applications "$DMG_STAGING/Applications"

# Output DMG
DMG_PATH="$DIR/LiveNotes.dmg"
rm -f "$DMG_PATH"

hdiutil create -volname "LiveNotes" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_PATH"

rm -rf "$DMG_STAGING"

echo "=========================================================="
echo "✅ Successfully built native macOS App and DMG!"
echo "📍 App : $APP_DIR"
echo "📍 DMG : $DMG_PATH"
echo "=========================================================="
