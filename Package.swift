// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MangaTL",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "MangaTL", targets: ["MangaTL"])],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", from: "1.19.2"),
    ],
    targets: [
        // ONNX Runtime's C API: the Objective-C wrapper can't disable the CPU memory arena,
        // which more than doubled per-stage peaks (see spike/PHASE0.md).
        .target(name: "COnnxRuntime", dependencies: [
            .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
        ]),
        .target(name: "MangaTLCore", dependencies: ["ZIPFoundation", "COnnxRuntime"]),
        .executableTarget(name: "MangaTL", dependencies: ["MangaTLCore"]),
        .testTarget(name: "MangaTLCoreTests", dependencies: ["MangaTLCore"]),
    ]
)
