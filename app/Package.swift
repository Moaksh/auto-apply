// swift-tools-version: 6.4
// AutoApply macOS app (SwiftUI, macOS 26+, Swift 6 language mode).
import PackageDescription

let package = Package(
    name: "AutoApply",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "AutoApply", targets: ["AutoApply"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "AutoApply",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/AutoApply",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "AutoApplyTests",
            dependencies: ["AutoApply"],
            path: "Tests/AutoApplyTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "C3Tests",
            dependencies: ["AutoApply"],
            path: "Tests/C3",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
