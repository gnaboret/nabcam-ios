// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NabcamCore",
    platforms: [.iOS(.v16), .macOS(.v10_15)],
    products: [.library(name: "NabcamCore", targets: ["NabcamCore"])],
    targets: [
        .target(name: "NabcamCore"),
        .testTarget(name: "NabcamCoreTests", dependencies: ["NabcamCore"])
    ]
)
