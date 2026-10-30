// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Unhandled",
    platforms: [.iOS(.v13), .macOS(.v10_15), .tvOS(.v13), .watchOS(.v6), .visionOS(.v1)],
    products: [
        .library(name: "Unhandled", targets: ["Unhandled"]),
    ],
    targets: [
        .target(name: "Unhandled"),
        .testTarget(name: "UnhandledTests", dependencies: ["Unhandled"]),
    ]
)
