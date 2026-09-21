#!/bin/bash
# Install the LaunchAgent so TeamsNotifier starts at login.
# Requires the app at /Applications/TeamsNotifier.app (Scripts/package.sh --install).
set -euo pipefail
cd "$(dirname "$0")/.."

AGENT="$HOME/Library/LaunchAgents/com.teamsnotifier.app.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cp Resources/LaunchAgent.plist "$AGENT"
launchctl unload "$AGENT" 2>/dev/null || true
launchctl load "$AGENT"
echo "loaded: $AGENT"
