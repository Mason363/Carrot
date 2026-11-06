// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ForewordKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ForewordEngine", targets: ["ForewordEngine"]),
        .executable(name: "foreword-eval", targets: ["ForewordEval"]),
    ],
    targets: [
        // llama.cpp's official Apple build (Metal, macOS 13.3+), pinned by release and checksum.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12177/llama-b12177-xcframework.zip",
            checksum: "5e1c930b7339821d6c9fa76554ed417d6a337b0ab8d97addfb3c274cf4306e61"
        ),
        .target(
            name: "ForewordEngine",
            dependencies: ["llama"],
            path: "Sources/ForewordEngine",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))],
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        .executableTarget(
            name: "ForewordEval",
            dependencies: ["ForewordEngine"],
            path: "Sources/ForewordEval"
        ),
        .testTarget(
            name: "ForewordEngineTests",
            dependencies: ["ForewordEngine"],
            path: "Tests/ForewordEngineTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
