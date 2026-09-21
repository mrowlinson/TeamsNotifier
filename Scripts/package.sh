#!/bin/bash
# Build release + wrap in TeamsNotifier.app (LSUIElement, single binary).
# Usage: Scripts/package.sh [--install]   (--install copies to /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release 2>&1 | tail -2

APP="tmp/TeamsNotifier.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/TeamsNotifier "$APP/Contents/MacOS/TeamsNotifier"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "built: $APP"
ls -la "$APP/Contents/MacOS/"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/TeamsNotifier.app
    cp -R "$APP" /Applications/TeamsNotifier.app
    echo "installed: /Applications/TeamsNotifier.app"
fi
