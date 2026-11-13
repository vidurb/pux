// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "pux-macos",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "PuxCore", targets: ["PuxCore"]),
        .executable(name: "pux", targets: ["PuxApp"]),
    ],
    targets: [
        .systemLibrary(
            name: "Clibsodium",
            pkgConfig: "libsodium",
            providers: [
                .brew(["libsodium"])
            ]
        ),
        .target(
            name: "PuxCore",
            dependencies: ["Clibsodium"],
            path: "Sources/PuxCore"
        ),
        .executableTarget(
            name: "PuxApp",
            dependencies: ["PuxCore"],
            path: "Sources/PuxApp"
        ),
        .testTarget(
            name: "PuxTests",
            dependencies: ["PuxCore"],
            path: "Tests/PuxTests"
        ),
    ]
)
