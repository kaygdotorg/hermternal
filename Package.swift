// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Hermternal",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "HermternalCore",
            path: "Sources/HermternalCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "Hermternal",
            dependencies: ["HermternalCore"],
            path: "Sources/Hermternal",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "HermternalCoreTests",
            dependencies: ["HermternalCore"],
            path: "Tests/HermternalCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
