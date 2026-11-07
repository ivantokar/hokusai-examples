// swift-tools-version: 6.0
import PackageDescription

// Framework-independent demo code: the versioned recipe model, the operation catalog, the compiler
// from a recipe to ordinary public Hokusai calls, the Swift code generator and the bounded upload
// store. Vapor and Hummingbird only adapt HTTP to this package; macOS consumes it directly.
let package = Package(
    name: "hokusai-recipes",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HokusaiRecipes", targets: ["HokusaiRecipes"]),
        .library(name: "HokusaiDemoServices", targets: ["HokusaiDemoServices"]),
        .executable(name: "recipes-tool", targets: ["recipes-tool"]),
    ],
    dependencies: [
        // Released versions only. To try unreleased changes see "Testing unreleased library changes" in the README.
        .package(url: "https://github.com/ivantokar/hokusai.git", from: "2.2.2"),
    ],
    targets: [
        .target(name: "HokusaiRecipes", dependencies: [.product(name: "Hokusai", package: "hokusai")]),
        .target(name: "HokusaiDemoServices", dependencies: ["HokusaiRecipes", .product(name: "Hokusai", package: "hokusai")]),
        .executableTarget(name: "recipes-tool", dependencies: ["HokusaiRecipes"]),
        .testTarget(name: "HokusaiRecipesTests", dependencies: ["HokusaiRecipes", "HokusaiDemoServices"]),
    ]
)
