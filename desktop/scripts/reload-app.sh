#!/usr/bin/env bash
# Build ChronicleDesktop, then replace and relaunch the .app only if the built
# binary or bundle metadata changed. Build failures leave the running app alone.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP_NAME="ChronicleDesktop"
BUNDLE_ID="com.chronicle.desktop"
APP="$APP_NAME.app"
APP_BIN="$APP/Contents/MacOS/$APP_NAME"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/chronicle-desktop-reload.XXXXXX")"
TMP_APP="$TMP_ROOT/$APP"
OLD_APP="$TMP_ROOT/old-$APP"

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

echo "Building $APP_NAME ($CONFIG)..."
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"

if [[ -x "$APP_BIN" ]] && cmp -s "$BIN" "$APP_BIN" && cmp -s Info.plist "$APP/Contents/Info.plist"; then
    echo "No app changes; leaving the running app untouched."
    exit 0
fi

mkdir -p "$TMP_APP/Contents/MacOS"
cp "$BIN" "$TMP_APP/Contents/MacOS/$APP_NAME"
cp Info.plist "$TMP_APP/Contents/Info.plist"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "Stopping running $APP_NAME..."
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true

    for _ in {1..20}; do
        pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
        sleep 0.1
    done

    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        pkill -x "$APP_NAME" || true
    fi

    for _ in {1..20}; do
        pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
        sleep 0.1
    done

    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        echo "Could not stop $APP_NAME; leaving the existing app bundle untouched." >&2
        exit 1
    fi
fi

if [[ -d "$APP" ]]; then
    mv "$APP" "$OLD_APP"
fi
mv "$TMP_APP" "$APP"

if ! open "$APP"; then
    echo "Failed to open $APP; restoring the previous bundle." >&2
    rm -rf "$APP"
    if [[ -d "$OLD_APP" ]]; then
        mv "$OLD_APP" "$APP"
    fi
    exit 1
fi

echo "Reloaded $APP."
