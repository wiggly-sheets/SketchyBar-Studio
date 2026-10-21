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
        .target(
            name: "CSketchyBar",
            path: "Sources/CSketchyBar",
            exclude: [
                "LICENSE.md",
                "MODIFICATIONS.md",
                "UPSTREAM.md"
            ],
            publicHeadersPath: "include",
            cSettings: [
                // The flags of the upstream makefile. The visibility flag
                // keeps the vendored symbols inside the target; the public
                // header marks its own exports with a default visibility.
                // The modules are off because the Darwin module declares
                // `struct group`, which the vendored group.h defines too.
                .unsafeFlags([
                    "-std=c99",
                    "-fvisibility=hidden",
                    "-fno-common",
                    "-fno-modules"
                ]),
                .headerSearchPath("shim"),
                .headerSearchPath("src")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreVideo")
            ]
        ),
        .executableTarget(
            name: "SketchyBarStudio",
            dependencies: ["CSketchyBar"],
            path: "Sources/SketchyBarStudio"
        ),
        .testTarget(
            name: "SketchyBarStudioTests",
            dependencies: ["SketchyBarStudio"],
            path: "Tests/SketchyBarStudioTests"
        )
    ]
)
