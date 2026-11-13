// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "pux",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v15),
        .macOS(.v14)
    ],
    products: [
        .library(name: "PuxCore", targets: ["PuxCore"]),
        .library(name: "PuxAppKit", targets: ["PuxApp"]),
        .library(name: "NotificationServiceKit", targets: ["NotificationServiceExtension"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jedisct1/swift-sodium.git", from: "0.11.0"),
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", exact: "13.1.1"),
    ],
    targets: [
        .target(
            name: "PuxCore",
            dependencies: [
                .product(name: "Sodium", package: "swift-sodium"),
            ],
            path: "Sources/PuxCore"
        ),
        .target(
            name: "PuxApp",
            dependencies: [
                "PuxCore",
                .product(name: "FirebaseMessaging", package: "firebase-ios-sdk"),
            ],
            path: "Sources/PuxApp",
            exclude: ["Info.plist", "Pux.entitlements", "PuxRelease.entitlements", "GoogleService-Info.plist"]
        ),
        .target(
            name: "NotificationServiceExtension",
            dependencies: [
                "PuxCore",
            ],
            path: "Sources/NotificationService",
            exclude: ["Info.plist", "NotificationService.entitlements"]
        ),
        .testTarget(
            name: "PuxCoreTests",
            dependencies: [
                "PuxCore",
            ],
            path: "Tests/PuxCoreTests"
        ),
    ]
)
