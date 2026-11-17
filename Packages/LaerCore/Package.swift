// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LaerCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LaerCore", targets: ["LaerCore"])
    ],
    targets: [
        .target(name: "LaerCore"),
        .testTarget(name: "LaerCoreTests", dependencies: ["LaerCore"]),
    ]
)
