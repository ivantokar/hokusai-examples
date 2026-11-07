// swift-tools-version: 6.0
import PackageDescription

// Native macOS playground. It evaluates Hokusai locally through the public API, works offline and
// needs neither Docker nor an HTTP server. Open this folder in Xcode, or run `swift run MacPlayground`.
let package = Package(
    name: "hokusai-examples-macos",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ivantokar/hokusai.git", from: "2.2.2"),
        .package(path: "../recipes"),
    ],
    targets: [
        // The model has no UI so it can be tested without a window.
        .target(name: "PlaygroundModel", dependencies: [
            .product(name: "Hokusai", package: "hokusai"),
            .product(name: "HokusaiRecipes", package: "recipes"),
        ]),
        .executableTarget(name: "MacPlayground", dependencies: ["PlaygroundModel", .product(name: "HokusaiRecipes", package: "recipes")],
                          resources: [.copy("Resources/fixtures")]),
        .testTarget(name: "PlaygroundModelTests", dependencies: ["PlaygroundModel"]),
    ]
)
