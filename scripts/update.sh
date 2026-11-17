#!/bin/bash
# Pulls the latest Launchpad, builds it and installs it into Applications.
# Usage: ~/launchpad/scripts/update.sh
set -euo pipefail
cd "$(dirname "$0")/.."
git pull --ff-only
./scripts/make-app.sh --install
