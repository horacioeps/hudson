// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hudson",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GmailKit", targets: ["GmailKit"]),
        .executable(name: "hudson", targets: ["HudsonCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(name: "GmailKit"),
        .executableTarget(
            name: "HudsonCLI",
            dependencies: [
                "GmailKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "GmailKitTests",
            dependencies: ["GmailKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
