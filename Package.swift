// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Harness",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DSHKit", targets: ["DSHKit"]),
        .executable(name: "Harness", targets: ["HarnessApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(name: "DSHKit", dependencies: ["Yams"]),
        .executableTarget(name: "HarnessApp", dependencies: ["DSHKit"]),
        .executableTarget(name: "harness-smoke", dependencies: ["DSHKit"]),
        .executableTarget(name: "webserver-smoke", dependencies: ["DSHKit"]),
        .testTarget(name: "DSHKitTests", dependencies: ["DSHKit"]),
    ]
)
