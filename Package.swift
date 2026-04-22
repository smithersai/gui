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
            name: "CGhosttyKit",
            path: "CGhosttyKit"
        ),
        .systemLibrary(
            name: "CSmithersKit",
            path: "CSmithersKit"
        ),
        .executableTarget(
            name: "SmithersGUI",
            dependencies: ["CGhosttyKit", "CSmithersKit"],
            path: ".",
            exclude: [
                "ghostty",
                "CGhosttyKit",
                "CSmithersKit",
                "tmux",
                "build.zig",
                ".zig-cache",
                "CONTRIBUTING.md",
                "README.md",
                "AGENTS.md",
                "Tests",
                "docs",
                "libsmithers",
                "linux",
                "scripts",
                "vercel",
                "LICENSE",
                "NOTICE",
                "project.yml",
                "smithers.db",
                "smithers.db-shm",
                "smithers.db-wal",
                ".worktrees",
                ".smithers",
                "vendor",
                "alchemy.run.ts",
                "package.json",
                "bun.lock",
                "node_modules",
                "build",
                "SmithersGUI.xcodeproj",
            ],
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Lghostty/macos/GhosttyKit.xcframework/macos-arm64",
                    "-Llibsmithers/zig-out/lib",
                    "-Llibsmithers",
                ]),
                .unsafeFlags([
                    "-lghostty-fat",
                    "-lsmithers",
                ]),
                .linkedLibrary("c++"),
                .linkedLibrary("resolv"),
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("sqlite3"),
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
