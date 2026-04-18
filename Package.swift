// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "TagBrowser",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "TagBrowser",
            targets: ["TagBrowser"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "TagBrowser",
            path: "Sources"
        ),
    ]
)
