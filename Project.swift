import ProjectDescription

let bundleID = "com.elliotfiske.JoyMapperSilicon"
let deployment: DeploymentTargets = .macOS("26.0")

/// macOS ties the Accessibility, Bluetooth and Microphone grants to the app's designated
/// requirement. An ad-hoc signature makes that a hash of the binary, so every rebuild silently
/// loses the grants (Settings still shows them on). Signing with a stable certificate makes it
/// "this bundle ID, signed by this certificate" instead.
///
/// The default is a self-signed certificate that only exists on this Mac; create it once with
/// `scripts/setup-local-signing.sh`. Override with `TUIST_SIGNING_IDENTITY=<name>`, or `-` for
/// ad-hoc (CI, or a Mac without the certificate; permissions then reset on every build).
let signingIdentity = Environment.signingIdentity.getString(default: "JoyMapper Silicon Local Signing")

let signingSettings: SettingsDictionary = [
    "CODE_SIGN_STYLE": "Manual",
    "CODE_SIGN_IDENTITY": .string(signingIdentity),
    "DEVELOPMENT_TEAM": "",
    // A self-signed certificate has no team; don't let Xcode insist on one.
    "OTHER_CODE_SIGN_FLAGS": "--timestamp=none",
]

let baseSettings: SettingsDictionary = signingSettings.merging([
    "SWIFT_VERSION": "5.0",
    "MACOSX_DEPLOYMENT_TARGET": "26.0",
]) { _, new in new }

let project = Project(
    name: "JoyMapperSilicon",
    packages: [
        .remote(
            url: "https://github.com/pointfreeco/swift-composable-architecture",
            requirement: .upToNextMajor(from: "1.26.2")
        ),
        .local(path: "Packages/BackgroundDriver"),
        // On-device Parakeet speech recognition (the dictation final pass).
        .remote(url: "https://github.com/FluidInference/FluidAudio", requirement: .upToNextMinor(from: "0.18.4")),
    ],
    settings: .settings(base: baseSettings),
    targets: [
        // MARK: - App
        .target(
            name: "JoyMapperSilicon",
            destinations: [.mac],
            product: .app,
            bundleId: bundleID,
            deploymentTargets: deployment,
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "JoyMapper Silicon",
                "CFBundleShortVersionString": "3.0",
                "CFBundleVersion": "1",
                "LSApplicationCategoryType": "public.app-category.utilities",
                // A regular Dock app, never a menu bar agent.
                "LSUIElement": false,
                "NSBluetoothAlwaysUsageDescription":
                    "JoyMapper Silicon connects to your Joy-Con 2 controllers over Bluetooth.",
                "NSMicrophoneUsageDescription":
                    "JoyMapper Silicon records your voice when you dictate.",
                "NSSpeechRecognitionUsageDescription":
                    "JoyMapper Silicon turns your dictation into text on this Mac.",
                "NSHumanReadableCopyright": "MIT License",
            ]),
            sources: ["App/Sources/**"],
            resources: ["App/Resources/Assets.xcassets"],
            entitlements: .file(path: "App/Resources/JoyMapperSilicon.entitlements"),
            dependencies: [
                .package(product: "ComposableArchitecture"),
                .package(product: "BackgroundDriver"),
                .package(product: "FluidAudio"),
            ],
            // Signing goes on the target: Tuist's target defaults would otherwise reset the
            // identity to ad-hoc.
            settings: .settings(
                base: signingSettings.merging([
                    "SWIFT_OBJC_BRIDGING_HEADER": "App/Sources/ObjC/JoyMapperSilicon-Bridging-Header.h",
                    "ENABLE_HARDENED_RUNTIME": "YES",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                ]) { _, new in new },
                // No hardened runtime in Debug: its library validation only loads code with the
                // app's Team ID, and a self-signed certificate has none, so it would reject the
                // debug dylib and the unit test bundle. Release keeps it.
                debug: ["ENABLE_HARDENED_RUNTIME": "NO"]
            )
        ),

        // MARK: - Unit tests: reducers, the Joy-Con 2 report parser, the mapping engine
        .target(
            name: "JoyMapperSiliconTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "\(bundleID).tests",
            deploymentTargets: deployment,
            infoPlist: .default,
            sources: ["Tests/Unit/**"],
            dependencies: [.target(name: "JoyMapperSilicon")],
            // Loaded into the hardened app, so library validation wants the same signer.
            settings: .settings(base: signingSettings)
        ),

        // MARK: - Background UI tests
        // Launch a fresh copy of the app in the background with simulated controllers, and drive it
        // through BackgroundDriver. No automation mode, no real mouse or keyboard.
        .target(
            name: "JoyMapperSiliconBackgroundUITests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "\(bundleID).backgrounduitests",
            deploymentTargets: deployment,
            infoPlist: .default,
            sources: ["Tests/BackgroundUI/**"],
            dependencies: [.package(product: "BackgroundDriverClient")],
            settings: .settings(base: ["CODE_SIGN_IDENTITY": "-"])
        ),

        // MARK: - Vendored JoyConSwift (Switch 1 HID). Not linked by the app today; kept for a
        // future Switch 1 Pro Controller transport.
        .target(
            name: "JoyConSwift",
            destinations: [.mac],
            product: .framework,
            bundleId: "com.elliotfiske.JoyConSwift",
            deploymentTargets: deployment,
            sources: ["Vendor/JoyConSwift/Sources/**/*.swift"],
            settings: .settings(base: ["DEFINES_MODULE": "YES"])
        ),
    ],
    schemes: [
        // ⌘U runs the unit tests. The background UI tests launch the app, so they have their own scheme.
        .scheme(
            name: "JoyMapperSilicon",
            shared: true,
            buildAction: .buildAction(targets: ["JoyMapperSilicon"]),
            testAction: .targets(["JoyMapperSiliconTests"], configuration: .debug),
            runAction: .runAction(executable: "JoyMapperSilicon")
        ),
        .scheme(
            name: "JoyMapperSiliconBackgroundUITests",
            shared: true,
            // The tests launch the app from the products directory, so build it too.
            buildAction: .buildAction(targets: ["JoyMapperSilicon", "JoyMapperSiliconBackgroundUITests"]),
            testAction: .targets(["JoyMapperSiliconBackgroundUITests"], configuration: .debug),
            runAction: .runAction(executable: "JoyMapperSilicon")
        ),
    ]
)
