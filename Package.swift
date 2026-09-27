// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CobbleChromium",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CobbleChromium", targets: ["CobbleChromium"]),
        .library(name: "CobbleChromiumClient", type: .dynamic, targets: ["ChromiumHarness"]),
    ],
    targets: [
        .target(name: "CCobbleChromium"),
        .target(name: "CobbleChromium", dependencies: ["CCobbleChromium"]),
        .target(name: "ChromiumHarness", dependencies: ["CobbleChromium"]),
        .testTarget(name: "CobbleChromiumTests", dependencies: ["CobbleChromium"]),
    ]
)
