// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "AiGallery",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "AiGallery",
            targets: ["AiGallery"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "AiGallery",
            path: "Sources"
        ),
    ]
)
