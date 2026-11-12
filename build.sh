#!/bin/bash
# Build and install "SAS Sync.app" into ~/Applications.
# The app bundles a renamed copy of terminal-notifier (Contents/Helpers) so pop-ups use the SAS Bulletin icon.
set -euo pipefail
cd "$(dirname "$0")"
APP_NAME="SAS Sync"
BUILD="build/$APP_NAME.app"
DEST="$HOME/Applications/$APP_NAME.app"
TN_SRC="$(dirname "$(readlink -f "$(command -v terminal-notifier)")")/../terminal-notifier.app"
[ -d "$TN_SRC" ] || TN_SRC="$(ls -d /opt/homebrew/Cellar/terminal-notifier/*/terminal-notifier.app | tail -1)"

rm -rf build && mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources" "$BUILD/Contents/Helpers"

echo "› Compiling"
swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
  -framework SwiftUI -framework WebKit -framework AppKit \
  Sources/main.swift -o "$BUILD/Contents/MacOS/SASSync"

echo "› Icon"
[ -f Resources/AppIcon.icns ] || python3 Resources/make_icon.py
cp Resources/AppIcon.icns "$BUILD/Contents/Resources/AppIcon.icns"

cat > "$BUILD/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>com.ianxie.sassync</string>
  <key>CFBundleExecutable</key><string>SASSync</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF

echo "› Notifier helper"
H="$BUILD/Contents/Helpers/$APP_NAME Notifier.app"
cp -R "$TN_SRC" "$H"; chmod -R u+w "$H"
cp Resources/AppIcon.icns "$H/Contents/Resources/Terminal.icns"
# keep the original notifier bundle id so macOS notification permission carries over
plutil -replace CFBundleIdentifier -string com.ianxie.sasbulletin "$H/Contents/Info.plist"
plutil -replace CFBundleName -string "$APP_NAME" "$H/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "$APP_NAME" "$H/Contents/Info.plist" 2>/dev/null \
  || plutil -insert CFBundleDisplayName -string "$APP_NAME" "$H/Contents/Info.plist"
plutil -replace LSUIElement -bool true "$H/Contents/Info.plist" 2>/dev/null \
  || plutil -insert LSUIElement -bool true "$H/Contents/Info.plist"

echo "› Signing (ad hoc)"
codesign --force --sign - "$H"
codesign --force --sign - "$BUILD"

echo "› Installing to $DEST"
mkdir -p "$HOME/Applications"
pkill -x SASBulletin 2>/dev/null || true; pkill -x SASSync 2>/dev/null || true
rm -rf "$DEST" "$HOME/Applications/SAS Bulletin.app"
cp -R "$BUILD" "$DEST"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -f "$DEST" "$DEST/Contents/Helpers/$APP_NAME Notifier.app"
echo "✓ Installed $DEST"
