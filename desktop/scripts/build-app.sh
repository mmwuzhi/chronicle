#!/usr/bin/env bash
# Package the SwiftPM executable into a .app bundle. A bundle (with a
# CFBundleIdentifier) is required for UNUserNotificationCenter — the reminder
# notifier traps at runtime when launched as a bare executable.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/ChronicleDesktop"

APP="ChronicleDesktop.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/ChronicleDesktop"
cp Info.plist "$APP/Contents/Info.plist"

echo "Built $APP — launch with: open $APP"
