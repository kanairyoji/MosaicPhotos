// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhotoSourceKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PhotoSourceKit", targets: ["PhotoSourceKit"]),
    ],
    targets: [
        .target(
            name: "PhotoSourceKit",
            path: "Sources/PhotoSourceKit"
        ),
        .testTarget(
            name: "PhotoSourceKitTests",
            dependencies: ["PhotoSourceKit"],
            path: "Tests/PhotoSourceKitTests"
        ),
    ]
)
