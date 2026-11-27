#!/bin/zsh
# Sends one request to the background driver in the running Debug build (see
# Packages/BackgroundDriver). It acts inside the app, so it never moves the real mouse.
# Usage: scripts/driver.sh GET '/elements?id=binding-value-'
#        scripts/driver.sh POST /click '{"id":"edit-a"}'
#        scripts/driver.sh GET /snapshot > window.png
# Set DRIVER_ENDPOINT to target a copy launched by the tests.
set -euo pipefail
endpoint=${DRIVER_ENDPOINT:-~/Library/Caches/com.elliotfiske.JoyMapperSilicon/background-driver.json}
[[ -f $endpoint ]] || { echo "No driver endpoint at $endpoint; is a Debug build running?" >&2; exit 1; }
port=$(plutil -extract port raw "$endpoint")
token=$(plutil -extract token raw "$endpoint")
pid=$(plutil -extract pid raw "$endpoint")
kill -0 "$pid" 2>/dev/null || { echo "The app that published $endpoint (pid $pid) isn't running." >&2; exit 1; }
curl -sS --max-time 15 -X "$1" -H "Authorization: Bearer $token" ${3:+-d "$3"} "http://127.0.0.1:$port$2"
