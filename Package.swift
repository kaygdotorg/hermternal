// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Hermternal",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Hermternal",
            path: "Sources/Hermternal",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
