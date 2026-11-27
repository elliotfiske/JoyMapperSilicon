// swift-tools-version: 6.0
import PackageDescription

/// Drives a macOS app from the inside: a loopback HTTP server, started by the app itself, that
/// finds elements by accessibility identifier and synthesizes clicks, hovers, and key presses
/// into the app's own windows. Nothing goes through the window server, so the real mouse and
/// keyboard stay free and the app can sit behind other windows.
let package = Package(
    name: "BackgroundDriver",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BackgroundDriver", targets: ["BackgroundDriver"]),
        .library(name: "BackgroundDriverClient", targets: ["BackgroundDriverClient"]),
    ],
    targets: [
        // Request and response types, shared so the two sides can't drift apart.
        .target(name: "BackgroundDriverModels"),
        // Inside the app: the server.
        .target(name: "BackgroundDriver", dependencies: ["BackgroundDriverModels"]),
        // Outside: launch or attach to the app and send it requests.
        .target(name: "BackgroundDriverClient", dependencies: ["BackgroundDriverModels"]),
        .testTarget(name: "BackgroundDriverTests", dependencies: ["BackgroundDriver", "BackgroundDriverClient"]),
    ]
)
