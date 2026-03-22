// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Denoise",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DenoiseApp", targets: ["DenoiseApp"]),
        .executable(name: "denoise", targets: ["DenoiseCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "CRNNoise",
            path: "Sources/CRNNoise",
            exclude: ["src/x86"],
            sources: ["src/"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .define("RNNOISE_BUILD"),
                .define("CPU_INFO_BY_C", to: "0"),
            ]
        ),
        .target(
            name: "DenoiseCore",
            dependencies: ["CRNNoise"],
            path: "Sources/DenoiseCore"
        ),
        .executableTarget(
            name: "DenoiseApp",
            dependencies: ["DenoiseCore"],
            path: "Sources/DenoiseApp"
        ),
        .executableTarget(
            name: "DenoiseCLI",
            dependencies: [
                "DenoiseCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/DenoiseCLI"
        ),
    ]
)
