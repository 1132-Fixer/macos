// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "1132 Fixer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "1132 Fixer", targets: ["1132Fixer"])
    ],
    targets: [
        .executableTarget(
            name: "1132Fixer",
            path: "Sources/1132Fixer",
            exclude: [
                "Info.plist",
                "1132Fixer.entitlements"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "1132FixerTests",
            dependencies: ["1132Fixer"],
            path: "Tests/1132FixerTests"
        )
    ]
)
