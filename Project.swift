import ProjectDescription

let project = Project(
    name: "JoyMapperSilicon",
    settings: .settings(
        base: [
            "DEVELOPMENT_TEAM": "CKGA64W25Z",
            "CODE_SIGN_STYLE": "Automatic",
            "SWIFT_VERSION": "5.0",
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
            deploymentTargets: .macOS("11.0"),
            infoPlist: .file(path: "JoyKeyMapper/Info.plist"),
            sources: ["JoyKeyMapper/**/*.swift"],
            resources: .resources(
                [
                    "JoyKeyMapper/Views/**/*.storyboard",
                    "JoyKeyMapper/Views/**/*.xib",
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
                .post(
                    script: """
                    mkdir -p "${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LoginItems"
                    cp -R "${BUILT_PRODUCTS_DIR}/JoyMapperSiliconLauncher.app" "${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LoginItems/"
                    """,
                    name: "Embed Login Items"
                ),
            ],
            dependencies: [
                .target(name: "JoyConSwift"),
                .target(name: "JoyMapperSiliconLauncher"),
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
            ),
            coreDataModels: [
                .coreDataModel("JoyKeyMapper/DataModels/JoyKeyMapper.xcdatamodeld"),
            ]
        ),

        // MARK: - Launcher Helper
        .target(
            name: "JoyMapperSiliconLauncher",
            destinations: [.mac],
            product: .app,
            bundleId: "cn.qibinc.JoyMapperSiliconLauncher",
            deploymentTargets: .macOS("11.0"),
            infoPlist: .file(path: "JoyKeyMapperLauncher/Info.plist"),
            sources: ["JoyKeyMapperLauncher/**/*.swift"],
            resources: .resources(
                [
                    "JoyKeyMapperLauncher/**/*.storyboard",
                    "JoyKeyMapperLauncher/Assets.xcassets",
                ]
            ),
            entitlements: .file(path: "JoyKeyMapperLauncher/JoyKeyMapperLauncher.entitlements"),
            settings: .settings(
                base: [
                    "ENABLE_HARDENED_RUNTIME": "YES",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                    "SKIP_INSTALL": "YES",
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
            deploymentTargets: .macOS("11.0"),
            sources: ["Vendor/JoyConSwift/Sources/**/*.swift"],
            settings: .settings(
                base: [
                    "DEFINES_MODULE": "YES",
                ]
            )
        ),
    ]
)
