// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SmithersGUI",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/nalexn/ViewInspector.git", from: "0.10.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CCodexFFI",
            path: "CCodexFFI"
        ),
        .systemLibrary(
            name: "CGhosttyKit",
            path: "CGhosttyKit"
        ),
        .executableTarget(
            name: "SmithersGUI",
            dependencies: ["CCodexFFI", "CGhosttyKit"],
            path: ".",
            exclude: [
                "codex",
                "ghostty",
                "CCodexFFI",
                "CGhosttyKit",
                "codex-ffi.h",
                "build.sh",
                "CONTRIBUTING.md",
                "Tests",
                "docs",
                "project.yml",
                "smithers.db",
                "smithers.db-shm",
                "smithers.db-wal",
                ".worktrees",
                ".smithers",
                "vendor",
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Lcodex/codex-rs/target/release",
                    "-Lghostty/macos/GhosttyKit.xcframework/macos-arm64",
                ]),
                .unsafeFlags([
                    "-lghostty-fat",
                ]),
                .linkedLibrary("c++"),
                .linkedLibrary("resolv"),
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("Foundation"),
            ]
        ),
        .testTarget(
            name: "SmithersGUITests",
            dependencies: [
                "SmithersGUI",
                .product(name: "ViewInspector", package: "ViewInspector"),
            ],
            path: "Tests/SmithersGUITests"
        ),
    ]
)
