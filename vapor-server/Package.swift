// swift-tools-version: 6.0
import PackageDescription

// The Vapor backend. Everything image-related goes through HokusaiVapor and the shared recipes package.
let package = Package(
    name: "hokusai-examples-vapor",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.89.0"),
        .package(url: "https://github.com/ivantokar/hokusai-vapor.git", from: "2.1.0"),
        .package(path: "../recipes"),
    ],
    targets: [
        .executableTarget(name: "App", dependencies: [
            .product(name: "Vapor", package: "vapor"),
            .product(name: "HokusaiVapor", package: "hokusai-vapor"),
            .product(name: "HokusaiRecipes", package: "recipes"),
            .product(name: "HokusaiDemoServices", package: "recipes"),
        ]),
    ]
)
