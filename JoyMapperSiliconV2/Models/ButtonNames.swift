// JoyMapperSiliconV2/Models/ButtonNames.swift
@preconcurrency import JoyConSwift

let buttonNames: [JoyCon.Button: String] = [
    .Up: "Up",
    .Right: "Right",
    .Down: "Down",
    .Left: "Left",
    .A: "A",
    .B: "B",
    .X: "X",
    .Y: "Y",
    .L: "L",
    .ZL: "ZL",
    .R: "R",
    .ZR: "ZR",
    .Minus: "Minus",
    .Plus: "Plus",
    .Capture: "Capture",
    .Home: "Home",
    .LStick: "LStick Push",
    .RStick: "RStick Push",
    .LeftSL: "Left SL",
    .LeftSR: "Left SR",
    .RightSL: "Right SL",
    .RightSR: "Right SR",
    .Start: "Start",
    .Select: "Select",
]

let directionNames: [JoyCon.StickDirection: String] = [
    .Up: "Up",
    .Right: "Right",
    .Down: "Down",
    .Left: "Left",
]

/// Which buttons each controller type has, in display order.
let controllerButtons: [JoyCon.ControllerType: [JoyCon.Button]] = [
    .JoyConL: [.Up, .Right, .Down, .Left, .LeftSL, .LeftSR, .L, .ZL, .Minus, .Capture, .LStick],
    .JoyConR: [.A, .B, .X, .Y, .RightSL, .RightSR, .R, .ZR, .Plus, .Home, .RStick],
    .ProController: [.A, .B, .X, .Y, .L, .ZL, .R, .ZR, .Up, .Right, .Down, .Left, .Minus, .Plus, .Capture, .Home, .LStick, .RStick],
    .FamicomController1: [.A, .B, .L, .R, .Up, .Right, .Down, .Left, .Start, .Select],
    .FamicomController2: [.A, .B, .L, .R, .Up, .Right, .Down, .Left],
]
