// swift-tools-version: 6.0
import PackageDescription

// The Hummingbird backend. Everything image-related goes through HokusaiHummingbird and the shared recipes package.
let package = Package(
    name: "hokusai-examples-hummingbird",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/ivantokar/hokusai-hummingbird.git", from: "2.1.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        .package(path: "../recipes"),
    ],
    targets: [
        .executableTarget(name: "App", dependencies: [
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "HokusaiHummingbird", package: "hokusai-hummingbird"),
            .product(name: "HTTPTypes", package: "swift-http-types"),
            .product(name: "HokusaiRecipes", package: "recipes"),
            .product(name: "HokusaiDemoServices", package: "recipes"),
        ]),
    ]
)
