#!/bin/bash
# Builds Launchpad.app into ./dist. Usage: ./scripts/make-app.sh [--open | --install]
# Lines starting "==> " are progress; scripts/update.sh logs them for the app's Update button. After an install the last
# one is "==> Note: …" (will macOS ask for your Keychain password again?), also written to LAUNCHPAD_NOTE_FILE if set.
# For testing: SWIFT_BUILD_FLAGS adds flags to swift build, LAUNCHPAD_INSTALL_DIR installs somewhere other than
# Applications, LAUNCHPAD_NO_OPEN=1 doesn't open the app afterwards, LAUNCHPAD_LOCAL_SIGNING=off signs ad-hoc and
# LAUNCHPAD_SIGN_TIMEOUT sets how many seconds to wait for a signing dialog (120).
set -euo pipefail
cd "$(dirname "$0")/.."
# The git calls below read this checkout, which bots may be able to write: run them with nothing from its config able to
# run a program. See scripts/safe-git.sh.
# shellcheck source=scripts/safe-git.sh
source ./scripts/safe-git.sh

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

# Signing, best first:
#  1. SIGN_IDENTITY set (the name or hash of a "Developer ID Application" certificate): hardened runtime and a
#     timestamp, ready to notarise (scripts/release.sh). A signing failure stops the build.
#  2. A certificate for local builds, so every build has the same identity and macOS keeps trusting Launchpad after an
#     update (no Keychain password prompt each time): an "Apple Development" certificate if your keychain has one
#     (Xcode makes it when you sign in with your Apple ID, and it carries your Team ID), else the local certificate
#     from scripts/setup-signing.sh. LAUNCHPAD_LOCAL_IDENTITY names a certificate; LAUNCHPAD_LOCAL_SIGNING=off skips this.
#  3. Ad-hoc: runs on this Mac only and is a new identity on every build, so macOS asks for your Keychain password
#     after each update. Also the fallback if signing with (2) didn't work, so an update isn't lost to a dialog
#     nobody answered; the note at the end of an install says so.
echo "==> Signing"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
LOCAL_IDENTITY="Launchpad Local Signing"
SIGN_KIND=""        # what the local certificate is called in messages
SIGN_FELL_BACK=""   # a local certificate was found but signing with it didn't work

# Gives up on a command after $1 seconds. The first signing with a certificate's key makes macOS ask "codesign wants to
# sign using key…", and an update nobody is watching shouldn't wait for that for ever.
with_timeout() { local secs="$1"; shift; perl -e 'alarm shift @ARGV; exec @ARGV' "$secs" "$@"; }

# Signs the two helpers and then the app with certificate $1 (a hash or a name), without the hardened runtime.
sign_local() {
  local limit="${LAUNCHPAD_SIGN_TIMEOUT:-120}" common=(--force --timestamp=none --sign "$1")
  with_timeout "$limit" codesign "${common[@]}" --identifier app.launchpad.personal.guard "$APP/Contents/MacOS/launchpad-guard" &&
    with_timeout "$limit" codesign "${common[@]}" --identifier app.launchpad.personal.chat "$APP/Contents/MacOS/launchpad-chat" &&
    with_timeout "$limit" codesign "${common[@]}" "$APP"
}

if [[ -n "$SIGN_IDENTITY" ]]; then
  SIGN=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
  codesign "${SIGN[@]}" --identifier app.launchpad.personal.guard "$APP/Contents/MacOS/launchpad-guard"
  codesign "${SIGN[@]}" --identifier app.launchpad.personal.chat "$APP/Contents/MacOS/launchpad-chat"
  codesign "${SIGN[@]}" --entitlements scripts/Launchpad.entitlements "$APP"
  SIGNED="signed as $SIGN_IDENTITY"
else
  LOCAL=""
  if [[ "${LAUNCHPAD_LOCAL_SIGNING:-on}" != "off" ]]; then
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    if [[ -n "${LAUNCHPAD_LOCAL_IDENTITY:-}" ]]; then
      LOCAL="$LAUNCHPAD_LOCAL_IDENTITY"; SIGN_KIND="the certificate you chose"
    elif LOCAL="$(awk '/"Apple Development:/ {print $2; exit}' <<<"$IDENTITIES")"; [[ -n "$LOCAL" ]]; then
      SIGN_KIND="your Apple Development certificate"
    elif grep -q "\"$LOCAL_IDENTITY\"" <<<"$IDENTITIES"; then
      LOCAL="$LOCAL_IDENTITY"; SIGN_KIND="your local certificate"
    fi
  fi
  if [[ -n "$LOCAL" ]] && sign_local "$LOCAL"; then
    SIGNED="signed with $SIGN_KIND"
  else
    [[ -n "$LOCAL" ]] && SIGN_FELL_BACK=1
    codesign --force --sign - "$APP"
    SIGNED="ad-hoc signed"
  fi
fi
codesign --verify --strict "$APP"
echo "Built $APP $VERSION ($BUILD), $SIGNED"

# What macOS trusts an app by. For a build signed with a certificate it names the certificate, so every update matches;
# for an ad-hoc build it is the hash of that one build, so none does.
designated() { { codesign -d -r- "$1" 2>&1 || true; } | sed -n 's/^# designated => //p'; }

# One plain sentence on whether macOS will ask for the Keychain password after this install. $1 is the requirement of
# the app that was installed before ("" if none), $2 the one just installed.
signature_note() {
  if [[ -n "$SIGN_FELL_BACK" ]]; then
    echo "Couldn't sign with $SIGN_KIND (macOS may have been waiting for you to let codesign use its key), so this build is ad-hoc signed and macOS will ask for your Keychain password again. Update again and, when macOS asks whether codesign can use the key, choose Always Allow."
  elif [[ -z "$2" || "$2" == cdhash* ]]; then
    echo "This build is ad-hoc signed, so macOS sees it as a new app and asks for your Keychain password after every update. To stop that, sign into Xcode with your Apple ID (it makes an Apple Development certificate) or run scripts/setup-signing.sh, then update again."
  elif [[ "$1" == "$2" ]]; then
    echo "Same signature as the app you had, so macOS should keep trusting it and not ask for your Keychain password."
  else
    echo "New signature (the first update signed this way): macOS may ask for your Keychain password once more. Choose Always Allow and it should stop asking."
  fi
}

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
    # Never asks for an admin password: /Applications if your user can write there, else ~/Applications.
    DIR="${LAUNCHPAD_INSTALL_DIR:-/Applications}"
    DIR_NOTE=""
    if [[ -z "${LAUNCHPAD_INSTALL_DIR:-}" && ! -w "$DIR" ]]; then
      DIR="$HOME/Applications"
      DIR_NOTE="Launchpad went into ~/Applications because /Applications needs an admin password for you."
      if [[ -e /Applications/Launchpad.app ]]; then DIR_NOTE="$DIR_NOTE The older copy in /Applications is still there: delete it so it doesn't open by mistake."; fi
    fi
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

    PREVIOUS=""
    if [[ -e "$DEST" ]]; then PREVIOUS="$(designated "$DEST")"; fi

    trap '' HUP INT TERM   # don't stop between the two renames
    if [[ -e "$DEST" ]]; then mv "$DEST" "$OLD"; fi
    if ! mv "$NEW" "$DEST"; then
      # Put the old app back.
      if [[ -e "$OLD" ]]; then mv "$OLD" "$DEST"; fi
      rm -rf "$NEW"
      echo "Couldn't put the new app in place. The old app has been put back." >&2
      exit 1
    fi
    rm -rf "$OLD" || echo "Couldn't delete the old copy at $OLD; it is safe to delete by hand." >&2
    echo "Installed $DEST"

    # Whether macOS will ask for the Keychain password again, in a line the update log and the app can show.
    NOTE="$(signature_note "$PREVIOUS" "$(designated "$DEST")")"
    if [[ -n "$DIR_NOTE" ]]; then NOTE="$NOTE $DIR_NOTE"; fi
    echo "==> Note: $NOTE"
    if [[ -n "${LAUNCHPAD_NOTE_FILE:-}" ]]; then printf '%s\n' "$NOTE" > "$LAUNCHPAD_NOTE_FILE"; fi
    if [[ -z "${LAUNCHPAD_NO_OPEN:-}" ]]; then
      echo "==> Opening Launchpad"
      open "$DEST"
    fi
    ;;
esac
