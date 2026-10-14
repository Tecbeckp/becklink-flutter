// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "becklinks_flutter",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "becklinks-flutter", targets: ["becklinks_flutter"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "becklinks_flutter",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                // Apple requires SDKs to ship their own privacy manifest.
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
