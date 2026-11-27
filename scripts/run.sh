#!/usr/bin/env bash
# Builds the Debug app and (re)launches it in the background, without taking focus.
# Logs: tail -f ~/Library/Logs/JoyMapperSilicon/joymapper.log
set -euo pipefail
cd "$(dirname "$0")/.."
mise exec -- tuist generate --no-open
xcodebuild build \
  -workspace JoyMapperSilicon.xcworkspace -scheme JoyMapperSilicon -destination 'platform=macOS' \
  -derivedDataPath build/dd -skipMacroValidation -skipPackagePluginValidation -quiet
osascript -e 'tell application id "com.elliotfiske.JoyMapperSilicon" to quit' 2>/dev/null || true
sleep 1
open -g build/dd/Build/Products/Debug/JoyMapperSilicon.app
echo "Launched. Log: ~/Library/Logs/JoyMapperSilicon/joymapper.log"
