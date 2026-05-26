// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "HerShared",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "HerShared", targets: ["HerShared"])
    ],
    targets: [
        .target(
            name: "HerShared",
            path: "Sources/HerShared"
        )
    ]
)
