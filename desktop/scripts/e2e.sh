#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/chronicle-desktop-e2e-clang-cache}"

bash scripts/build-app.sh debug

export CHRONICLE_DESKTOP_E2E_APP_PATH="$PWD/ChronicleDesktop.app/Contents/MacOS/ChronicleDesktop"

swift test --filter ChronicleDesktopE2ETests
