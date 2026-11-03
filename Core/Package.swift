// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UnpackCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "UnpackCore", targets: ["UnpackCore"])],
    targets: [
        .target(name: "UnpackCore"),
        .testTarget(
            name: "UnpackCoreTests",
            dependencies: ["UnpackCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
