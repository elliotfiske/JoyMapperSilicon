// swift-tools-version: 6.0
import PackageDescription

/// Runs saved dictation recordings through several speech recognizers and writes a side-by-side
/// HTML report. A development tool, not part of the app.
let package = Package(
    name: "SpeechBakeoff",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "SpeechBakeoff",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
