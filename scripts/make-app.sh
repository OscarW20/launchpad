#!/bin/bash
# Builds Launchpad.app into ./dist. Usage: ./scripts/make-app.sh [--open | --install]
set -euo pipefail
cd "$(dirname "$0")/.."

# The version is the newest v* tag (v0.2.0 gives 0.2.0; 0.1.0 until there is one) and the build number is the
# commit count. DESCRIBE names the exact commit, e.g. v0.2.0-3-gabc1234 three commits after the tag.
TAG="$(git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null || true)"
VERSION="${TAG#v}"
VERSION="${VERSION:-0.1.0}"
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "Tag $TAG isn't a version like v0.2.0" >&2
  exit 1
fi
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
DESCRIBE="$(git describe --tags --match 'v[0-9]*' --always --dirty 2>/dev/null || true)"

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
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LaunchpadGitDescribe</key><string>$DESCRIBE</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSAppleEventsUsageDescription</key><string>A bot working in Launchpad wants to control another app.</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# App icon from the brand iconset.
iconutil -c icns "Sources/Launchpad/Resources/Brand/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# Signing. With SIGN_IDENTITY set (the name or hash of a "Developer ID Application" certificate in your keychain)
# the helpers and then the app are signed with the hardened runtime and a timestamp, ready to notarise. Without it
# the app gets an ad-hoc signature, which runs on this Mac only. A signing failure stops the build.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -n "$SIGN_IDENTITY" ]]; then
  SIGN=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
  codesign "${SIGN[@]}" --identifier app.launchpad.personal.guard "$APP/Contents/MacOS/launchpad-guard"
  codesign "${SIGN[@]}" --identifier app.launchpad.personal.chat "$APP/Contents/MacOS/launchpad-chat"
  codesign "${SIGN[@]}" --entitlements scripts/Launchpad.entitlements "$APP"
  SIGNED="signed as $SIGN_IDENTITY"
else
  codesign --force --sign - "$APP"
  SIGNED="ad-hoc signed"
fi
codesign --verify --strict "$APP"
echo "Built $APP $VERSION ($BUILD), $SIGNED"

case "${1:-}" in
  --open)
    open "$APP"
    ;;
  --install)
    # Quit a running copy, replace /Applications/Launchpad.app, and open it.
    osascript -e 'tell application id "app.launchpad.personal" to quit' >/dev/null 2>&1 || true
    sleep 1
    DEST="/Applications/Launchpad.app"
    if [ ! -w /Applications ]; then mkdir -p "$HOME/Applications"; DEST="$HOME/Applications/Launchpad.app"; fi
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    echo "Installed $DEST"
    open "$DEST"
    ;;
esac
