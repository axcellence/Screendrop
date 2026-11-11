#!/bin/zsh
# Build this fork and install it as /Applications/Screendrop.app.
#
#   scripts/install-fork.sh
#
# Needs Xcode 26.4 or newer, signed in to the team set in the project. Replaces whatever
# Screendrop.app is already in /Applications, including the official release.
set -euo pipefail

cd "$(dirname "$0")/.."
build="${TMPDIR:-/tmp}/screendrop-fork-build"

echo "Building…"
xcodebuild build \
  -project Screendrop.xcodeproj \
  -scheme Screendrop \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "$build" \
  2>&1 | grep -E "(BUILD SUCCEEDED|BUILD FAILED|error:)" || true

app="$build/Build/Products/Release/Screendrop.app"
if [[ ! -d "$app" ]]; then
  echo "Build did not produce $app" >&2
  exit 1
fi

osascript -e 'tell application "Screendrop" to quit' >/dev/null 2>&1 || true
sleep 1

# First install on this Mac: start from the official app's settings rather than from scratch.
# The fork has its own bundle ID, so it would otherwise not see them. Never overwrites settings
# the fork already has.
official="com.fayazahmed.Screendrop"
fork="com.axcellence.Screendrop"
if ! defaults read "$fork" >/dev/null 2>&1 && defaults read "$official" >/dev/null 2>&1; then
  echo "Copying settings from the official app…"
  defaults export "$official" - | defaults import "$fork" -
fi

echo "Installing to /Applications…"
rm -rf /Applications/Screendrop.app
ditto "$app" /Applications/Screendrop.app
open /Applications/Screendrop.app
echo "Installed Screendrop $(defaults read /Applications/Screendrop.app/Contents/Info CFBundleShortVersionString) (fork)."
