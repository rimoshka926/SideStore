// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VIOSLCore",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [
        .library(name: "VIOSLCore", targets: ["VIOSLCore"])
    ],
    targets: [
        .target(name: "VIOSLCore", path: "Sources/VIOSLCore"),
        .testTarget(
            name: "VIOSLCoreTests",
            dependencies: ["VIOSLCore"],
            path: "Tests/VIOSLCoreTests"
        )
    ]
)
