// swift-tools-version: 6.0

// Copyright 2026 Mars Pater
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.14.3"),
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
