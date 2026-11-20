#!/bin/bash
# Pulls the latest Launchpad, builds it and installs it into Applications.
# Usage: ~/launchpad/scripts/update.sh
#
# Safe to start from inside the app (the Update button): the app you're running is only replaced once the new one
# has built, and everything is written to a log the app reads, ~/Library/Logs/Launchpad/update.log (or
# LAUNCHPAD_UPDATE_LOG). Lines starting "==> " are progress; the last one is "==> Done: …" or "==> Failed: …".
set -euo pipefail

# The whole script is one function, so bash has read all of it before `git pull` can replace this file.
main() {
  cd "$(dirname "$0")/.."
  # git as the app runs it: no hook, filesystem monitor or credential helper from this checkout's config can run, and
  # origin is checked before anything is fetched. See scripts/safe-git.sh.
  # shellcheck source=scripts/safe-git.sh
  source ./scripts/safe-git.sh

  LOG="${LAUNCHPAD_UPDATE_LOG:-$HOME/Library/Logs/Launchpad/update.log}"
  mkdir -p "$(dirname "$LOG")"

  # One update at a time.
  LOCK="$LOG.lock"
  if ! mkdir "$LOCK" 2>/dev/null; then
    if kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null; then
      echo "update: another update is already running." >&2
      exit 1
    fi
    rm -rf "$LOCK"
    mkdir "$LOCK"
  fi
  echo $$ > "$LOCK/pid"

  # Everything goes to the log. In Terminal you see it too; started from the app there is nobody to print to, and
  # printing to an app that has just quit would stop the update halfway.
  : > "$LOG"
  if [[ -t 1 ]]; then exec > >(tee -a "$LOG") 2>&1; else exec >>"$LOG" 2>&1; fi
  say() { echo "$*"; }
  REASON=""
  fail() { REASON="$*"; exit 1; }
  finish() {
    local code=$?
    rm -rf "$LOCK"
    if [[ $code -ne 0 ]]; then
      say "==> Failed: ${REASON:-the build or install stopped (see the lines above). The app you had is unchanged.}"
    fi
  }
  trap finish EXIT

  say "==> Checking for updates"
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  [[ "$BRANCH" == "main" ]] || fail "this checkout is on \"$BRANCH\", not main. Run: git switch main"
  [[ -z "$(git status --porcelain --untracked-files=no)" ]] \
    || fail "there are uncommitted changes in $(pwd -P). Commit or discard them, then update again."
  trusted_origin || fail "this checkout's origin isn't Launchpad's own GitHub repository (or the checkout rewrites URLs), so nothing was fetched. In $(pwd -P) check: git remote -v"
  git fetch --quiet origin || fail "couldn't reach GitHub. Check your connection and try again."
  if git merge-base --is-ancestor HEAD origin/main; then
    say "==> Getting the latest code"
    git merge --ff-only origin/main || fail "couldn't fast-forward to GitHub's main."
  elif ! git merge-base --is-ancestor origin/main HEAD; then
    # Commits here that GitHub doesn't have, and commits there that this checkout doesn't.
    fail "this checkout and GitHub's main have gone separate ways (diverged). In $(pwd -P) run: git pull --rebase"
  fi

  # The build script may be newer than the one that was here when this started; run the new one. It leaves a note on
  # whether macOS will ask for your Keychain password again, which goes on the end of the Done line so the app shows it.
  NOTE_FILE="$LOG.note"
  rm -f "$NOTE_FILE"
  LAUNCHPAD_NOTE_FILE="$NOTE_FILE" ./scripts/make-app.sh --install
  NOTE=""
  if [[ -s "$NOTE_FILE" ]]; then NOTE=" $(head -n 1 "$NOTE_FILE")"; fi
  rm -f "$NOTE_FILE"
  say "==> Done: Launchpad is up to date at $(git rev-parse --short HEAD).${NOTE}"
}

main "$@"
exit
