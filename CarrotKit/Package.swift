// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CarrotKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CarrotEngine", targets: ["CarrotEngine"]),
        .executable(name: "carrot-eval", targets: ["CarrotEval"]),
    ],
    targets: [
        // llama.cpp's official Apple build (Metal, macOS 13.3+), pinned by release and checksum.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12177/llama-b12177-xcframework.zip",
            checksum: "5e1c930b7339821d6c9fa76554ed417d6a337b0ab8d97addfb3c274cf4306e61"
        ),
        .target(
            name: "CarrotEngine",
            dependencies: ["llama"],
            path: "Sources/CarrotEngine",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))],
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        .executableTarget(
            name: "CarrotEval",
            dependencies: ["CarrotEngine"],
            path: "Sources/CarrotEval"
        ),
        .testTarget(
            name: "CarrotEngineTests",
            dependencies: ["CarrotEngine"],
            path: "Tests/CarrotEngineTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
