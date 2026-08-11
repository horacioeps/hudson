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
        .library(name: "Outbox", targets: ["Outbox"]),
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
        // MIME building + send state machine (spec §7). Depends on GmailKit
        // for the `SentMessage`/`SendTransport` shapes SendService (a later
        // M5 task) sends through, and Store for the `send_jobs` durable
        // queue it persists to — declared now so the whole target compiles
        // as later Task-3-adjacent M5 tasks land in the same directory.
        .target(name: "Outbox", dependencies: ["GmailKit", "Store"]),
        .testTarget(
            name: "OutboxTests",
            dependencies: ["Outbox"],
            resources: [.copy("Golden")]
        ),
    ]
)
