// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MineRushCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "MineRushCore", targets: ["MineRushCore"]),
    ],
    targets: [
        .target(name: "MineRushCore"),
        .testTarget(name: "MineRushCoreTests", dependencies: ["MineRushCore"]),
    ]
)
