// swift-tools-version: 5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Lightpack",
    platforms: [
        .macOS(.v12),
        .iOS(.v14),
        .tvOS(.v14),
        .watchOS(.v6)
    ],
    products: [
        .library(
            name: "Lightpack",
            targets: ["Lightpack"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ggerganov/llama.cpp", branch: "master")
    ],
    targets: [
        .target(
            name: "Lightpack",
            dependencies: [.product(name: "llama", package: "llama.cpp")]),
        .testTarget(
            name: "LightpackTests",
            dependencies: ["Lightpack"]),
    ]
)
