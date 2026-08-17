// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "YourPods",
    platforms: [
        .iOS("18.0"),
        .macOS(.v14)
    ],
    products: [
        .library(name: "YourPods", targets: ["YourPods"]),
    ],
    targets: [
        .target(
            name: "YourPods",
            path: "YourPods/YourPods"
        ),
    ]
)
