#!/usr/bin/env bash
# Generates the Xcode project and runs the tests.
# Usage: scripts/test.sh [unit|ui|all]
# Builds into build/dd-test, so it never replaces the copy scripts/run.sh launched.
#   unit (default)  reducers, the Joy-Con 2 protocol parser and the mapping engine. Headless.
#   ui              the background UI tests: a fresh copy of the app with simulated Joy-Cons,
#                   driven through BackgroundDriver. It stays behind your windows and never
#                   touches the real mouse or keyboard, so it's safe to run while you work.
#   all             both.
set -euo pipefail
cd "$(dirname "$0")/.."

mise exec -- tuist generate --no-open

run() {
  local scheme=$1
  shift
  xcodebuild test \
    -workspace JoyMapperSilicon.xcworkspace \
    -scheme "$scheme" \
    -destination 'platform=macOS' \
    -derivedDataPath build/dd-test \
    -skipMacroValidation -skipPackagePluginValidation \
    "$@"
}

case "${1:-unit}" in
  unit) run JoyMapperSilicon ;;
  ui)   run JoyMapperSiliconBackgroundUITests ;;
  all)  run JoyMapperSilicon && run JoyMapperSiliconBackgroundUITests ;;
  *)    echo "usage: $0 [unit|ui|all]" >&2; exit 64 ;;
esac
