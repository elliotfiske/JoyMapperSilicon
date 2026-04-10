// swift-tools-version: 5.10
// This file is used by Tuist to resolve external dependencies.
import PackageDescription

#if TUIST
import ProjectDescription

let packageSettings = PackageSettings(
    productTypes: [
        "Sharing": .framework,
    ]
)
#endif

let package = Package(
    name: "JoyMapperSilicon",
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.0.0"),
    ]
)
