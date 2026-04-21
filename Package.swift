// swift-tools-version: 6.0

import PackageDescription
import Foundation

// Local-only CLI detection. The `Mutex` executable target is gitignored
// (Sources/Mutex/). When present on disk, the manifest wires it up + pulls
// swift-argument-parser; on a fresh clone neither exists, so the published
// package stays CLI-free without a manual Package.swift swap.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let hasCLI = FileManager.default.fileExists(atPath: packageRoot + "/Sources/Mutex/main.swift")

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/ordo-one/package-benchmark", .upToNextMajor(from: "1.0.0")),
    .package(url: "https://github.com/apple/swift-nio", from: "2.86.2"),
    .package(url: "https://github.com/HdrHistogram/hdrhistogram-swift.git", .upToNextMajor(from: "0.1.0")),
]
if hasCLI {
    dependencies.append(.package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"))
}

var targets: [Target] = [
    .target(
        name: "CFutexShims"
    ),
    .target(
        name: "MutexBench",
        dependencies: [
            .product(name: "Benchmark", package: "package-benchmark"),
            .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            .product(name: "Histogram", package: "hdrhistogram-swift"),
            "CFutexShims",
        ]
    ),
    .executableTarget(
        name: "ContentionScaling",
        dependencies: [
            .product(name: "Benchmark", package: "package-benchmark"),
            "MutexBench",
        ],
        path: "Benchmarks/ContentionScaling",
        plugins: [
            .plugin(name: "BenchmarkPlugin", package: "package-benchmark"),
        ]
    ),
    .executableTarget(
        name: "HoldTime",
        dependencies: [
            .product(name: "Benchmark", package: "package-benchmark"),
            "MutexBench",
        ],
        path: "Benchmarks/HoldTime",
        plugins: [
            .plugin(name: "BenchmarkPlugin", package: "package-benchmark"),
        ]
    ),
    .executableTarget(
        name: "ContentionRatio",
        dependencies: [
            .product(name: "Benchmark", package: "package-benchmark"),
            "MutexBench",
        ],
        path: "Benchmarks/ContentionRatio",
        plugins: [
            .plugin(name: "BenchmarkPlugin", package: "package-benchmark"),
        ]
    ),
    .executableTarget(
        name: "CacheLevels",
        dependencies: [
            .product(name: "Benchmark", package: "package-benchmark"),
            "MutexBench",
        ],
        path: "Benchmarks/CacheLevels",
        plugins: [
            .plugin(name: "BenchmarkPlugin", package: "package-benchmark"),
        ]
    ),
    .executableTarget(
        name: "SpinTuning",
        dependencies: [
            .product(name: "Benchmark", package: "package-benchmark"),
            "MutexBench",
            "CFutexShims",
        ],
        path: "Benchmarks/SpinTuning",
        plugins: [
            .plugin(name: "BenchmarkPlugin", package: "package-benchmark"),
        ]
    ),
    .executableTarget(
        name: "NanosecondContention",
        dependencies: [
            .product(name: "Benchmark", package: "package-benchmark"),
            "MutexBench",
        ],
        path: "Benchmarks/NanosecondContention",
        plugins: [.plugin(name: "BenchmarkPlugin", package: "package-benchmark")]
    ),
    .executableTarget(
        name: "BackgroundLoad",
        dependencies: [
            .product(name: "Benchmark", package: "package-benchmark"),
            "MutexBench",
        ],
        path: "Benchmarks/BackgroundLoad",
        plugins: [.plugin(name: "BenchmarkPlugin", package: "package-benchmark")]
    ),
    .executableTarget(
        name: "Asymmetric",
        dependencies: [
            .product(name: "Benchmark", package: "package-benchmark"),
            "MutexBench",
        ],
        path: "Benchmarks/Asymmetric",
        plugins: [.plugin(name: "BenchmarkPlugin", package: "package-benchmark")]
    ),
    .executableTarget(
        name: "LongRun",
        dependencies: [
            .product(name: "Benchmark", package: "package-benchmark"),
            "MutexBench",
        ],
        path: "Benchmarks/LongRun",
        plugins: [.plugin(name: "BenchmarkPlugin", package: "package-benchmark")]
    ),
    .executableTarget(
        name: "Bursty",
        dependencies: [
            .product(name: "Benchmark", package: "package-benchmark"),
            "MutexBench",
        ],
        path: "Benchmarks/Bursty",
        plugins: [.plugin(name: "BenchmarkPlugin", package: "package-benchmark")]
    ),
]
if hasCLI {
    targets.append(.executableTarget(
        name: "Mutex",
        dependencies: [
            .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            "MutexBench",
        ],
        path: "Sources/Mutex"
    ))
}

targets.append(.testTarget(
    name: "MutexBenchTests",
    dependencies: ["MutexBench"],
    path: "Tests/MutexBenchTests"
))

let package = Package(
    name: "MutexBench",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MutexBench", targets: ["MutexBench"]),
    ],
    dependencies: dependencies,
    targets: targets
)
