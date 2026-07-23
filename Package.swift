// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SketchyBarStudio",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SketchyBarStudio", targets: ["SketchyBarStudio"])
    ],
    targets: [
        .executableTarget(
            name: "SketchyBarStudio",
            path: "Sources/SketchyBarStudio"
        ),
        .testTarget(
            name: "SketchyBarStudioTests",
            dependencies: ["SketchyBarStudio"],
            path: "Tests/SketchyBarStudioTests"
        )
    ]
)
