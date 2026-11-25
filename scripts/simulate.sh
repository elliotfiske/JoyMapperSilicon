#!/usr/bin/env bash
# Sends simulated input to a copy of the app launched with JOYMAPPER_SIMULATED_CONTROLLERS.
# Usage: scripts/simulate.sh SIM-joyCon2Right a,zr [x] [y]   # hold A and ZR, stick at x,y (-1…1)
#        scripts/simulate.sh SIM-joyCon2Right ""             # release everything
#        scripts/simulate.sh SIM-joyCon2Left disconnect
set -euo pipefail
cat > /tmp/joymapper-simulate.swift <<'SWIFT'
import Foundation
let args = Array(CommandLine.arguments.dropFirst())
var info = ["id": args[0]]
let second = args.count > 1 ? args[1] : ""
if second == "disconnect" || second == "connect" {
    info["action"] = second
} else {
    info["buttons"] = second
    info["x"] = args.count > 2 ? args[2] : "0"
    info["y"] = args.count > 3 ? args[3] : "0"
}
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.elliotfiske.JoyMapperSilicon.simulate"),
    object: nil, userInfo: info, deliverImmediately: true)
SWIFT
swift /tmp/joymapper-simulate.swift "$@"
