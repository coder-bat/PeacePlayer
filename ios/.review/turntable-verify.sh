#!/bin/bash
#
# turntable-verify.sh
#
# Builds the Turntable Home, installs it on a booted simulator with
# ff_turntable_home enabled, launches it, and captures screenshots.
#
# Usage:
#   ./ios/.review/turntable-verify.sh [simulator-name]
#
# The flag lives in the app's own UserDefaults domain, so it has to be
# written AFTER the app has been installed (the container does not
# exist before that) and the app must be relaunched for the change to
# be picked up.

set -euo pipefail

SIM_NAME="${1:-iPhone 16 Pro}"
BUNDLE_ID="com.ytaudioplayer.app"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS_DIR="$ROOT/ios"
OUT_DIR="$IOS_DIR/.review"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

mkdir -p "$OUT_DIR"

echo "▸ Resolving simulator: $SIM_NAME"
SIM_ID="$(xcrun simctl list devices available \
  | grep -E "^\s+${SIM_NAME} \(" \
  | head -1 \
  | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"

if [ -z "$SIM_ID" ]; then
  echo "✗ Simulator '$SIM_NAME' not found." >&2
  exit 1
fi
echo "  id=$SIM_ID"

echo "▸ Building"
cd "$IOS_DIR"
xcodegen generate > /dev/null
xcodebuild \
  -project YTAudioPlayer.xcodeproj \
  -scheme YTAudioPlayer \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  -configuration Debug \
  build \
  -derivedDataPath "$IOS_DIR/build/turntable-verify" \
  | grep -E "error:|BUILD" || true

APP_PATH="$(find "$IOS_DIR/build/turntable-verify/Build/Products/Debug-iphonesimulator" \
  -maxdepth 1 -name "PeacePlayer.app" | head -1)"

if [ -z "$APP_PATH" ]; then
  echo "✗ Built app not found." >&2
  exit 1
fi
echo "  app=$APP_PATH"

echo "▸ Booting simulator"
xcrun simctl boot "$SIM_ID" 2>/dev/null || true
xcrun simctl bootstatus "$SIM_ID" -b > /dev/null 2>&1 || true

echo "▸ Installing"
xcrun simctl uninstall "$SIM_ID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$SIM_ID" "$APP_PATH"

echo "▸ Enabling ff_turntable_home"
# Launch once so the app creates its UserDefaults container.
xcrun simctl launch "$SIM_ID" "$BUNDLE_ID" > /dev/null 2>&1 || true
sleep 3
xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" 2>/dev/null || true

CONTAINER="$(xcrun simctl get_app_container "$SIM_ID" "$BUNDLE_ID" data)"
PLIST="$CONTAINER/Library/Preferences/$BUNDLE_ID.plist"

if [ ! -f "$PLIST" ]; then
  echo "  (no preferences plist yet - using simctl spawn)"
  xcrun simctl spawn "$SIM_ID" defaults write "$BUNDLE_ID" ff_turntable_home -bool YES
else
  /usr/libexec/PlistBuddy -c "Delete :ff_turntable_home" "$PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :ff_turntable_home bool true" "$PLIST"
  echo "  wrote $PLIST"
fi

echo "▸ Launching"
xcrun simctl launch "$SIM_ID" "$BUNDLE_ID" > /dev/null
sleep 6

echo "▸ Capturing"
xcrun simctl io "$SIM_ID" screenshot "$OUT_DIR/turntable-home.png"
echo "  → $OUT_DIR/turntable-home.png"

echo "✓ done"
