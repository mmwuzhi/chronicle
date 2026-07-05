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
INSTALL_DIR="${CHRONICLE_DESKTOP_INSTALL_DIR:-/Applications}"
INSTALLED_APP="$INSTALL_DIR/$APP"
INSTALLED_APP_BIN="$INSTALLED_APP/Contents/MacOS/$APP_NAME"
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

bundle_matches() {
    local bundle_bin="$1"
    local bundle_info="$2"

    [[ -x "$bundle_bin" ]] && cmp -s "$BIN" "$bundle_bin" && cmp -s Info.plist "$bundle_info"
}

local_changed=0
installed_changed=0

if ! bundle_matches "$APP_BIN" "$APP/Contents/Info.plist"; then
    local_changed=1
fi

if ! bundle_matches "$INSTALLED_APP_BIN" "$INSTALLED_APP/Contents/Info.plist"; then
    installed_changed=1
fi

if [[ "$local_changed" -eq 0 && "$installed_changed" -eq 0 ]] && pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "No app changes; installed copy is current; leaving the running app untouched."
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

if [[ "$local_changed" -eq 1 && -d "$APP" ]]; then
    mv "$APP" "$OLD_APP"
fi
if [[ "$local_changed" -eq 1 ]]; then
    ditto "$TMP_APP" "$APP"
fi

if [[ "$installed_changed" -eq 1 ]]; then
    echo "Installing $APP to $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR"
    ditto "$TMP_APP" "$INSTALLED_APP"
fi

if ! open "$INSTALLED_APP"; then
    echo "Failed to open $INSTALLED_APP." >&2
    if [[ "$local_changed" -eq 1 ]]; then
        echo "Restoring the previous local bundle." >&2
        rm -rf "$APP"
        if [[ -d "$OLD_APP" ]]; then
            mv "$OLD_APP" "$APP"
        fi
    fi
    exit 1
fi

echo "Reloaded $INSTALLED_APP."
