#!/bin/bash
# Build release + wrap in TeamsNotifier.app (LSUIElement, single binary).
# Usage: Scripts/package.sh [--install]   (--install copies to /Applications)
#
# Signing: CODESIGN_IDENTITY env wins; else the first "Apple Development"
# identity from `security find-identity`; else ad-hoc (loud warning:
# macOS may refuse notification authorization for ad-hoc-signed apps).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release 2>&1 | tail -2

APP="tmp/TeamsNotifier.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/TeamsNotifier "$APP/Contents/MacOS/TeamsNotifier"
cp Resources/Info.plist "$APP/Contents/Info.plist"

IDENT="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"' || true)}"
if [[ -z "${IDENT:-}" ]]; then
    echo "WARNING: no Apple Development identity found; signing ad-hoc."
    echo "WARNING: macOS may refuse notification authorization for ad-hoc-signed apps."
    echo "WARNING: set CODESIGN_IDENTITY or add an Apple Development identity to fix."
    codesign --force --sign - "$APP/Contents/MacOS/TeamsNotifier"
    codesign --force --sign - "$APP"
else
    echo "signing with: $IDENT"
    codesign --force --sign "$IDENT" "$APP/Contents/MacOS/TeamsNotifier"
    codesign --force --sign "$IDENT" "$APP"
fi
codesign --verify --verbose=1 "$APP"

echo "built: $APP"
ls -la "$APP/Contents/MacOS/"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/TeamsNotifier.app
    cp -R "$APP" /Applications/TeamsNotifier.app
    echo "installed: /Applications/TeamsNotifier.app"
fi
