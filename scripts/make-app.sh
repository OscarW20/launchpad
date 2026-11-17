#!/bin/bash
# Builds Launchpad.app into ./dist. Usage: ./scripts/make-app.sh [--open]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Launchpad
swift build -c release --product launchpad-guard
swift build -c release --product launchpad-chat
BINDIR="$(swift build -c release --show-bin-path)"
BIN="$BINDIR/Launchpad"

APP="dist/Launchpad.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Launchpad"
cp "$BINDIR/launchpad-guard" "$APP/Contents/MacOS/launchpad-guard"
cp "$BINDIR/launchpad-chat" "$APP/Contents/MacOS/launchpad-chat"
# Logos and brand images (menu bar icon), found by AppResources in Contents/Resources.
if [[ -d "$BINDIR/Launchpad_Launchpad.bundle" ]]; then
  cp -R "$BINDIR/Launchpad_Launchpad.bundle" "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Launchpad</string>
  <key>CFBundleDisplayName</key><string>Launchpad</string>
  <key>CFBundleIdentifier</key><string>app.launchpad.personal</string>
  <key>CFBundleExecutable</key><string>Launchpad</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# App icon from the brand iconset.
iconutil -c icns "Sources/Launchpad/Resources/Brand/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so macOS will run it locally.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"

if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
