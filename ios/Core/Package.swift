// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NabcamCore",
    products: [.library(name: "NabcamCore", targets: ["NabcamCore"])],
    targets: [
        .target(name: "NabcamCore"),
        .testTarget(name: "NabcamCoreTests", dependencies: ["NabcamCore"])
    ]
)
