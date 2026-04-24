import ProjectDescription

let project = Project(
    name: "JoyMapperSilicon",
    settings: .settings(
        base: [
            "DEVELOPMENT_TEAM": "CKGA64W25Z",
            "CODE_SIGN_STYLE": "Automatic",
            "SWIFT_VERSION": "6.0",
        ],
        debug: [
            "ENABLE_TESTABILITY": "YES",
        ]
    ),
    targets: [
        // MARK: - Main App
        .target(
            name: "JoyMapperSilicon",
            destinations: [.mac],
            product: .app,
            bundleId: "com.elliotfiske.JoyMapperSilicon",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .file(path: "JoyKeyMapper/Info.plist"),
            sources: ["JoyMapperSiliconV2/**/*.swift"],
            resources: .resources(
                [
                    "JoyKeyMapper/Assets.xcassets",
                    "JoyKeyMapper/Misc/*.strings",
                ]
            ),
            entitlements: .file(path: "JoyKeyMapper/JoyKeyMapper.entitlements"),
            scripts: [
                .post(
                    path: "scripts/set_build_number.sh",
                    name: "Set build number"
                ),
            ],
            dependencies: [
                .target(name: "JoyConSwift"),
                .external(name: "Sharing"),
            ],
            settings: .settings(
                base: [
                    "ENABLE_HARDENED_RUNTIME": "YES",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                    "CURRENT_PROJECT_VERSION": "10",
                    "MARKETING_VERSION": "1.0",
                    "CODE_SIGN_ENTITLEMENTS": "JoyKeyMapper/JoyKeyMapper.entitlements",
                ],
                configurations: [
                    .debug(name: "Debug"),
                    .release(name: "Release"),
                ]
            )
        ),

        // MARK: - Vendored JoyConSwift
        .target(
            name: "JoyConSwift",
            destinations: [.mac],
            product: .framework,
            bundleId: "com.elliotfiske.JoyConSwift",
            deploymentTargets: .macOS("26.0"),
            sources: ["Vendor/JoyConSwift/Sources/**/*.swift"],
            settings: .settings(
                base: [
                    "DEFINES_MODULE": "YES",
                    "SWIFT_VERSION": "5.0",
                ]
            )
        ),
    ]
)
