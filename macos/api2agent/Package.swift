// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "api2agent",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "api2agentCore", targets: ["api2agentCore"]),
        .executable(name: "api2agent", targets: ["api2agent"]),
        .executable(name: "API2AgentServer", targets: ["API2AgentServer"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0")
    ],
    targets: [
        .target(
            name: "api2agentCore",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "api2agent",
            dependencies: [
                "api2agentCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "API2AgentServer",
            dependencies: ["api2agentCore"],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "api2agentTests",
            dependencies: ["api2agentCore", "api2agent"],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        )
    ]
)
