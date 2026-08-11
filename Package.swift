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
        .library(name: "AIKit", targets: ["AIKit"]),
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
                "Outbox",
                "AIKit",
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
        .testTarget(name: "HudsonCLITests", dependencies: ["HudsonCLI", "Outbox", "Store", "AIKit"]),
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
        // for the `SentMessage`/`SendTransport` shapes SendService sends
        // through, and Store for the `send_jobs` durable queue it persists to.
        .target(name: "Outbox", dependencies: ["GmailKit", "Store"]),
        .testTarget(
            name: "OutboxTests",
            dependencies: ["Outbox", "Store"],
            resources: [.copy("Golden")]
        ),
        // AIKit composes ONLY Store (retrieval/cache/config) + GmailKit for the
        // LLMKeyStore secret seam — never GmailKit's network client (spec §8:
        // "Uses Store and its own providers. Never touches GmailKit").
        .target(name: "AIKit", dependencies: ["Store", "GmailKit"]),
        .testTarget(name: "AIKitTests", dependencies: ["AIKit", "Store"]),
    ]
)
