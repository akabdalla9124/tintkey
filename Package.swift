// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tintkey",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TintkeyKit", targets: ["TintkeyKit"]),
        .executable(name: "tintkey-probe", targets: ["tintkey-probe"]),
        .executable(name: "Tintkey", targets: ["Tintkey"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "TintkeyKit", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "tintkey-probe", dependencies: ["TintkeyKit"]),
        .testTarget(name: "TintkeyKitTests", dependencies: ["TintkeyKit"]),
        .executableTarget(name: "Tintkey", dependencies: ["TintkeyKit", .product(name: "Sparkle", package: "Sparkle")]),
    ]
)
