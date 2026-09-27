// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "News",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "News", targets: ["News"])
    ],
    targets: [
        .executableTarget(
            name: "News",
            path: "Sources"
        )
    ]
)
