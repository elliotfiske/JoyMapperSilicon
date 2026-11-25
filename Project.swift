import ProjectDescription

let bundleID = "com.elliotfiske.JoyMapperSilicon"
let deployment: DeploymentTargets = .macOS("26.0")

/// Sign with a real Apple Development certificate. macOS ties the Accessibility grant to the
/// signer, so an ad-hoc signature (new on every build) loses the grant at each rebuild.
let signingSettings: SettingsDictionary = [
    "DEVELOPMENT_TEAM": "CKGA64W25Z",
    "CODE_SIGN_STYLE": "Automatic",
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
                "NSHumanReadableCopyright": "MIT License",
            ]),
            sources: ["App/Sources/**"],
            resources: ["App/Resources/Assets.xcassets"],
            entitlements: .file(path: "App/Resources/JoyMapperSilicon.entitlements"),
            dependencies: [
                .package(product: "ComposableArchitecture"),
                .package(product: "BackgroundDriver"),
            ],
            settings: .settings(base: [
                "ENABLE_HARDENED_RUNTIME": "YES",
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            ])
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
            dependencies: [.target(name: "JoyMapperSilicon")]
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
