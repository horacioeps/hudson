// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hudson",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GmailKit", targets: ["GmailKit"]),
        .executable(name: "hudson", targets: ["HudsonCLI"]),
        .library(name: "HudsonUI", targets: ["HudsonUI"]),
        .executable(name: "HudsonApp", targets: ["HudsonApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(name: "GmailKit"),
        .executableTarget(
            name: "HudsonCLI",
            dependencies: [
                "GmailKit",
                "Store",
                "SyncEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "GmailKitTests",
            dependencies: ["GmailKit"],
            resources: [.copy("Fixtures")]
        ),
        .target(name: "Store", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "StoreTests", dependencies: ["Store"]),
        .testTarget(name: "HudsonCLITests", dependencies: ["HudsonCLI"]),
        .target(name: "SyncEngine", dependencies: ["GmailKit", "Store"]),
        .testTarget(name: "SyncEngineTests", dependencies: ["SyncEngine"]),
        .target(
            name: "HudsonUI",
            dependencies: ["GmailKit", "Store", "SyncEngine",
                           .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "HudsonApp", dependencies: ["HudsonUI"]),
        .testTarget(name: "HudsonUITests", dependencies: ["HudsonUI", "Store"]),
    ]
)
