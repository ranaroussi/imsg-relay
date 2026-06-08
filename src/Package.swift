// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImsgRelay",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "ImsgRelay",
            targets: ["ImsgRelay"]
        )
    ],
    dependencies: [
        // iMessage core — chat.db reads, watcher, AppleScript send surface
        .package(url: "https://github.com/openclaw/imsg.git", from: "0.11.0"),

        // Auto-updates
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),

        // Local HTTP API
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.5.0"),

        // Official MCP Swift SDK (stdio server transport).
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),

        // SQLite for the retry queue and cursor persistence.
        // Already transitively required by IMsgCore; pinning here so the
        // queue layer can depend on it explicitly without surprise upgrades.
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.5")
    ],
    targets: [
        .executableTarget(
            name: "ImsgRelay",
            dependencies: [
                .product(name: "IMsgCore", package: "imsg"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "SQLite", package: "SQLite.swift")
            ],
            path: "Sources",
            exclude: [
                "Resources/README.md"
            ],
            resources: [
                .copy("Resources")
            ],
            linkerSettings: [
                .linkedFramework("ScriptingBridge"),
                .linkedFramework("Contacts")
            ]
        )
    ]
)
