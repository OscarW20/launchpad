#!/bin/bash
# Builds Launchpad.app into ./dist. Usage: ./scripts/make-app.sh [--open | --install]
# Lines starting "==> " are progress; scripts/update.sh logs them for the app's Update button.
# For testing: SWIFT_BUILD_FLAGS adds flags to swift build, LAUNCHPAD_INSTALL_DIR installs somewhere other than
# Applications, and LAUNCHPAD_NO_OPEN=1 doesn't open the app afterwards.
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
# The exact commit and this checkout's folder, so the app can tell when main has moved on and where to update from.
COMMIT="$(git rev-parse HEAD 2>/dev/null || true)"
SOURCE="$(pwd -P)"
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

echo "==> Building Launchpad $VERSION ($BUILD)"
# shellcheck disable=SC2086
swift build ${SWIFT_BUILD_FLAGS:-} -c release --product Launchpad
# shellcheck disable=SC2086
swift build ${SWIFT_BUILD_FLAGS:-} -c release --product launchpad-guard
# shellcheck disable=SC2086
swift build ${SWIFT_BUILD_FLAGS:-} -c release --product launchpad-chat
# shellcheck disable=SC2086
BINDIR="$(swift build ${SWIFT_BUILD_FLAGS:-} -c release --show-bin-path)"
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
  <key>LaunchpadGitCommit</key><string>$COMMIT</string>
  <key>LaunchpadSourcePath</key><string>$(xml "$SOURCE")</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSAppleEventsUsageDescription</key><string>A bot working in Launchpad wants to control another app.</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Create ticket with Claude</string></dict>
      <key>NSMessage</key><string>createTicket</string>
      <key>NSPortName</key><string>Launchpad</string>
      <key>NSSendTypes</key>
      <array><string>NSStringPboardType</string><string>public.utf8-plain-text</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# App icon from the brand iconset.
iconutil -c icns "Sources/Launchpad/Resources/Brand/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# Signing. With SIGN_IDENTITY set (the name or hash of a "Developer ID Application" certificate in your keychain)
# the helpers and then the app are signed with the hardened runtime and a timestamp, ready to notarise. Without it
# the app gets an ad-hoc signature, which runs on this Mac only. A signing failure stops the build.
echo "==> Signing"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
LOCAL_IDENTITY="Launchpad Local Signing"
if [[ -n "$SIGN_IDENTITY" ]]; then
  SIGN=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
  codesign "${SIGN[@]}" --identifier app.launchpad.personal.guard "$APP/Contents/MacOS/launchpad-guard"
  codesign "${SIGN[@]}" --identifier app.launchpad.personal.chat "$APP/Contents/MacOS/launchpad-chat"
  codesign "${SIGN[@]}" --entitlements scripts/Launchpad.entitlements "$APP"
  SIGNED="signed as $SIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$LOCAL_IDENTITY\""; then
  # Your own local certificate (scripts/setup-signing.sh). The signature stays the same from build to build,
  # so the Keychain and Privacy settings keep trusting Launchpad after each update.
  LSIGN=(--force --sign "$LOCAL_IDENTITY")
  codesign "${LSIGN[@]}" --identifier app.launchpad.personal.guard "$APP/Contents/MacOS/launchpad-guard"
  codesign "${LSIGN[@]}" --identifier app.launchpad.personal.chat "$APP/Contents/MacOS/launchpad-chat"
  codesign "${LSIGN[@]}" "$APP"
  SIGNED="signed with your local certificate"
else
  codesign --force --sign - "$APP"
  SIGNED="ad-hoc signed (run scripts/setup-signing.sh once so macOS stops asking for your Keychain password after updates)"
fi
codesign --verify --strict "$APP"
echo "Built $APP $VERSION ($BUILD), $SIGNED"

# The copy of Launchpad running from the app at $1, if any (one process id per line).
# -a: pgrep leaves out its own ancestors otherwise, and when the app's Update button starts this, the app is one.
running_from() { pgrep -a -f "^$1/Contents/MacOS/Launchpad" || true; }

case "${1:-}" in
  --open)
    open "$APP"
    ;;
  --install)
    # Replaces the installed app without ever leaving you with none: the new app is copied in next to the old
    # one first, the running copy is asked to quit, and only then are the two swapped (a rename, which can't
    # half-finish). If anything fails before the swap, the old app is untouched.
    DIR="${LAUNCHPAD_INSTALL_DIR:-/Applications}"
    if [[ -z "${LAUNCHPAD_INSTALL_DIR:-}" && ! -w "$DIR" ]]; then DIR="$HOME/Applications"; fi
    mkdir -p "$DIR"
    DEST="$DIR/Launchpad.app"
    NEW="$DIR/.Launchpad.new.app"
    OLD="$DIR/.Launchpad.old.app"

    echo "==> Installing into $DIR"
    rm -rf "$NEW" "$OLD"
    if ! ditto "$APP" "$NEW"; then
      rm -rf "$NEW"
      echo "Couldn't copy the new app into $DIR. The installed app is unchanged." >&2
      exit 1
    fi

    if [[ -n "$(running_from "$DEST")" ]]; then
      echo "==> Waiting for Launchpad to quit"
      osascript -e "tell application \"$DEST\" to quit" >/dev/null 2>&1 || true
      for _ in $(seq 1 30); do [[ -z "$(running_from "$DEST")" ]] && break; sleep 0.5; done
      if [[ -n "$(running_from "$DEST")" ]]; then
        # It didn't answer the polite request (a sheet open, or it's busy): end it.
        running_from "$DEST" | xargs kill 2>/dev/null || true
        for _ in $(seq 1 20); do [[ -z "$(running_from "$DEST")" ]] && break; sleep 0.5; done
      fi
      if [[ -n "$(running_from "$DEST")" ]]; then
        rm -rf "$NEW"
        echo "Launchpad is still running and wouldn't quit. Quit it and run this again; the installed app is unchanged." >&2
        exit 1
      fi
    fi

    trap '' HUP INT TERM   # don't stop between the two renames
    if [[ -e "$DEST" ]]; then mv "$DEST" "$OLD"; fi
    if ! mv "$NEW" "$DEST"; then
      # Put the old app back.
      if [[ -e "$OLD" ]]; then mv "$OLD" "$DEST"; fi
      rm -rf "$NEW"
      echo "Couldn't put the new app in place. The old app has been put back." >&2
      exit 1
    fi
    rm -rf "$OLD"
    echo "Installed $DEST"
    if [[ -z "${LAUNCHPAD_NO_OPEN:-}" ]]; then
      echo "==> Opening Launchpad"
      open "$DEST"
    fi
    ;;
esac
