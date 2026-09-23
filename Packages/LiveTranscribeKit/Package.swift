// swift-tools-version: 6.2
//
// LiveTranscribeKit — every vertical slice of the pipeline is its own target so that
// cross-slice dependencies are explicit and compiler-enforced. Only the MLX-backed
// adapters (SileroSegmenter, MLXTranscriber, MLXCleaner) touch MLX types; the UI never does.
//
// Build note: SwiftPM on the command line cannot compile MLX's Metal shaders. Build and
// test with `xcodebuild` (see README.md), which produces the metallib bundle.

import PackageDescription

let strictSwift: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "LiveTranscribeKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "LiveTranscribeKit",
            targets: [
                "Shared", "Capture", "Segmentation", "Transcription", "Cleanup",
                "Persistence", "Session", "TranscriptUI", "MLXSupport", "Styles",
            ]
        ),
        .executable(name: "Bench", targets: ["Bench"]),
        .executable(name: "Train", targets: ["Train"]),
    ],
    dependencies: [
        // Pinned exactly. mlx-audio-swift must be pinned by revision (tag v0.1.3) because its
        // manifest uses unsafeFlags, which SwiftPM only accepts from revision-pinned packages.
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "d302a5c6080d2bb97bae38c7418f82abb76013b6"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.6"),
        // Downloader + tokenizer implementations required by mlx-swift-lm 3.x (already
        // transitive dependencies of mlx-audio-swift; declared so Cleanup can adapt them).
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.11.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.4"),
    ],
    targets: [
        // MARK: - Slices

        .target(name: "Shared", swiftSettings: strictSwift),

        .target(name: "Capture", dependencies: ["Shared"], swiftSettings: strictSwift),

        // The deterministic text rules the cleanup levels turn on (fillers, lists).
        .target(name: "Styles", dependencies: ["Shared"], swiftSettings: strictSwift),

        .target(
            name: "Segmentation",
            dependencies: [
                "Shared",
                .product(name: "MLXAudioVAD", package: "mlx-audio-swift"),
                .product(name: "MLX", package: "mlx-swift"),
            ],
            swiftSettings: strictSwift
        ),

        .target(
            name: "Transcription",
            dependencies: [
                "Shared",
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            swiftSettings: strictSwift
        ),

        .target(
            name: "Cleanup",
            dependencies: [
                "Shared", "Styles",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            // The fine-tuned LoRA adapter that resolves spoken self-corrections (see Training/).
            resources: [.copy("Adapter")],
            swiftSettings: strictSwift
        ),

        .target(name: "Persistence", dependencies: ["Shared"], swiftSettings: strictSwift),

        .target(
            name: "Session",
            dependencies: ["Shared", "Capture", "Segmentation", "Transcription", "Cleanup", "Persistence"],
            swiftSettings: strictSwift
        ),

        .target(name: "TranscriptUI", dependencies: ["Shared", "Session", "Capture"], swiftSettings: strictSwift),

        // Process-wide MLX configuration (GPU buffer cache). Kept out of Shared so Shared
        // stays dependency-free.
        .target(
            name: "MLXSupport",
            dependencies: ["Shared", .product(name: "MLX", package: "mlx-swift")],
            swiftSettings: strictSwift
        ),

        .executableTarget(
            name: "Bench",
            dependencies: [
                "Shared", "Capture", "Segmentation", "Transcription", "Cleanup",
                "Persistence", "Session", "MLXSupport",
            ],
            swiftSettings: strictSwift
        ),

        // Development only: builds the self-correction dataset and trains, saves and evaluates
        // the cleanup adapter. The app does not depend on it.
        .target(
            name: "CleanupTraining",
            dependencies: [
                "Shared", "Cleanup", "MLXSupport", "Styles",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXOptimizers", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            swiftSettings: strictSwift
        ),

        .executableTarget(
            name: "Train",
            dependencies: ["Shared", "Cleanup", "CleanupTraining", "MLXSupport"],
            swiftSettings: strictSwift
        ),

        // MARK: - Tests

        .testTarget(name: "SharedTests", dependencies: ["Shared"], swiftSettings: strictSwift),
        .testTarget(name: "StylesTests", dependencies: ["Styles"], swiftSettings: strictSwift),
        .testTarget(name: "CaptureTests", dependencies: ["Capture", "Shared"], swiftSettings: strictSwift),
        .testTarget(name: "SegmentationTests", dependencies: ["Segmentation", "Shared"], swiftSettings: strictSwift),
        .testTarget(
            name: "CleanupTests",
            dependencies: ["Cleanup", "Shared", .product(name: "HuggingFace", package: "swift-huggingface")],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "CleanupTrainingTests",
            dependencies: [
                "CleanupTraining", "Cleanup", "Shared",
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            swiftSettings: strictSwift
        ),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "Shared"], swiftSettings: strictSwift),
        .testTarget(
            name: "SessionTests",
            dependencies: ["Session", "Shared", "Capture", "Segmentation", "Transcription", "Cleanup", "Persistence"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "TranscriptUITests",
            dependencies: ["TranscriptUI", "Session", "Shared", "Capture"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "Shared", "Capture", "Segmentation", "Transcription", "Cleanup",
                "Persistence", "Session", "MLXSupport",
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: strictSwift
        ),
    ]
)
