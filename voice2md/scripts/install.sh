#!/bin/bash
# Build the Release .app and install it to /Applications.
# After this runs you can launch Voice2MD from Spotlight, Launchpad,
# Finder, or by double-clicking — Xcode is no longer needed.

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen is required: brew install xcodegen" >&2
    exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "xcodebuild not found. Install Xcode from the App Store." >&2
    exit 1
fi

echo "Generating Xcode project..."
xcodegen generate >/dev/null

echo "Building Release configuration (this is fast — under a minute)..."
xcodebuild \
    -project Voice2MD.xcodeproj \
    -scheme Voice2MD \
    -configuration Release \
    -derivedDataPath build \
    build 2>&1 | tail -3

APP_SOURCE="build/Build/Products/Release/Voice2MD.app"
APP_DEST="/Applications/Voice2MD.app"

if [ ! -d "$APP_SOURCE" ]; then
    echo "Build did not produce $APP_SOURCE — see logs above." >&2
    exit 1
fi

echo "Quitting any running instance..."
osascript -e 'quit app "Voice2MD"' 2>/dev/null || true
sleep 1

echo "Installing to $APP_DEST..."
if [ -d "$APP_DEST" ]; then
    rm -rf "$APP_DEST"
fi
cp -R "$APP_SOURCE" "$APP_DEST"

# Locally-built apps don't get quarantined, but strip just in case.
xattr -dr com.apple.quarantine "$APP_DEST" 2>/dev/null || true

echo "Launching..."
open "$APP_DEST"

cat <<EOF

Installed at $APP_DEST.
Look for the waveform icon in the menu bar.

To launch automatically at login:
  Click the menu bar icon -> Settings... -> General -> Launch at Login.
  macOS will ask you to approve in System Settings -> General -> Login Items.

To uninstall:
  Quit the app, then: rm -rf "$APP_DEST"

EOF
