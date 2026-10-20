// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "News",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "News", targets: ["News"]),
        .library(name: "NewsParsingDependencies", type: .static, targets: ["NewsParsingDependencies"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.5"),
        .package(url: "https://github.com/nmdias/FeedKit.git", from: "10.9.4"),
    ],
    targets: [
        .target(
            name: "NewsParsingDependencies",
            dependencies: [
                .product(name: "SwiftSoup", package: "SwiftSoup"), .product(name: "FeedKit", package: "FeedKit"),
            ],
            path: "BuildSupport"
        ),
        .executableTarget(
            name: "News",
            dependencies: [
                .product(name: "SwiftSoup", package: "SwiftSoup"), .product(name: "FeedKit", package: "FeedKit"),
            ],
            path: "Sources",
            resources: [.copy("ThirdPartyNotices.txt"), .copy("Resources")]
        ),
    ]
)
