#!/bin/bash
# Releases Launchpad from this Mac: tags the version, builds and signs the app, notarises it with Apple and
# publishes the zip as a GitHub release.
# Usage: ./scripts/release.sh 0.2.0            release version 0.2.0
#        ./scripts/release.sh 0.2.0 --check    only check this Mac is ready; changes nothing
#
# One-off setup:
#   1. A "Developer ID Application" certificate in your keychain (Xcode > Settings > Accounts > Manage Certificates).
#   2. A notarisation login saved in your keychain (you type the password in Terminal; it is stored nowhere else):
#        xcrun notarytool store-credentials launchpad-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
#   3. The GitHub CLI, signed in: gh auth login
#
# SIGN_IDENTITY picks a certificate when you have more than one; NOTARY_PROFILE names another keychain profile.
set -euo pipefail
cd "$(dirname "$0")/.."
# git with nothing from this checkout's config able to run a program, and nothing in the environment able to redirect
# it. Your own global git config is kept: tagging needs your identity. See scripts/safe-git.sh.
export LAUNCHPAD_GIT_USE_GLOBAL=1
# shellcheck source=scripts/safe-git.sh
source ./scripts/safe-git.sh

fail() { echo "release: $*" >&2; exit 1; }

VERSION="${1:-}"
CHECK_ONLY=""
[[ "${2:-}" == "--check" ]] && CHECK_ONLY=1
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "give a version like 0.2.0 (usage: ./scripts/release.sh 0.2.0 [--check])"
TAG="v$VERSION"
PROFILE="${NOTARY_PROFILE:-launchpad-notary}"

# --- Checks: everything that could stop a release, before anything is changed. ---

[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || fail "you're not on main. Run: git switch main"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || fail "there are uncommitted changes. Commit or discard them first."
trusted_origin || fail "origin isn't Launchpad's own GitHub repository (or this checkout rewrites URLs), so nothing was fetched or pushed. Check: git remote -v"
git fetch --quiet --tags origin || fail "couldn't reach GitHub (git fetch failed)."
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
  || fail "this checkout isn't level with GitHub's main. Run: git pull --ff-only (or push your commits)"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then fail "tag $TAG already exists. Pick the next version."; fi

command -v gh >/dev/null || fail "the GitHub CLI isn't installed. Run: brew install gh"
gh auth status >/dev/null 2>&1 || fail "the GitHub CLI isn't signed in. Run: gh auth login"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  # The certificate's hash, so two certificates with the same name can't be confused.
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk '/"Developer ID Application:/ {print $2; exit}')"
fi
[[ -n "$SIGN_IDENTITY" && "$SIGN_IDENTITY" != "-" ]] || fail "no \"Developer ID Application\" certificate in your keychain.
  Create one in Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application, then run this again."
security find-identity -v -p codesigning | grep -q -F "$SIGN_IDENTITY" \
  || fail "the certificate \"$SIGN_IDENTITY\" isn't in your keychain (see: security find-identity -v -p codesigning)."

xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || fail "the notarisation login \"$PROFILE\" is missing or no longer works.
  Save it once (you'll be asked for an app-specific password from account.apple.com):
    xcrun notarytool store-credentials $PROFILE --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID"

if [[ -n "$CHECK_ONLY" ]]; then
  echo "Ready to release $VERSION: certificate, notarisation login and GitHub sign-in all found."
  exit 0
fi

# --- Tag (on this Mac only for now), build and sign. ---

# make-app.sh takes the version from the tag. The tag is pushed only once Apple has accepted the app; if anything
# fails before that, it is removed again so the release can simply be re-run.
git tag -a "$TAG" -m "Launchpad $VERSION"
PUSHED=""
cleanup() { if [[ -z "$PUSHED" ]]; then git tag -d "$TAG" >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT

APP="dist/Launchpad.app"
ZIP="dist/Launchpad-$VERSION.zip"
SIGN_IDENTITY="$SIGN_IDENTITY" ./scripts/make-app.sh
BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$BUILT" == "$VERSION" ]] || fail "the app built as version $BUILT, not $VERSION."

# --- Notarise, staple and check. ---

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Sending to Apple for notarisation (usually a few minutes)..."
RESULT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait --output-format json)" \
  || fail "couldn't send the app to Apple for notarisation."
STATUS="$(printf '%s' "$RESULT" | plutil -extract status raw -o - - 2>/dev/null || true)"
if [[ "$STATUS" != "Accepted" ]]; then
  ID="$(printf '%s' "$RESULT" | plutil -extract id raw -o - - 2>/dev/null || true)"
  fail "Apple didn't accept the app (status: ${STATUS:-unknown}). See why with:
    xcrun notarytool log $ID --keychain-profile $PROFILE"
fi
xcrun stapler staple "$APP"
spctl --assess --type execute "$APP" || fail "Gatekeeper rejects the notarised app."
# Zip again so the download carries the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# --- Publish. ---

git_gh push origin "$TAG"
PUSHED=1
gh release create "$TAG" "$ZIP" --title "Launchpad $VERSION" --generate-notes
echo "Released Launchpad $VERSION. The signed app is also at $APP."
