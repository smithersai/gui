// swift-tools-version: 5.9
import PackageDescription

// NOTE (ticket 0121):
//   iOS is a first-class target alongside macOS. Most Swift sources compile on
//   both platforms. Platform-specific code (AppKit, the macos/Sources/Smithers
//   support layer, TerminalView, macOS helper binaries) stays macOS-only via
//   `#if os(macOS)` guards and/or platform-gated target membership.
//
//   The executable target below is still macOS-only at the SwiftPM layer
//   because it links the macOS-only libghostty-fat and libsmithers static
//   archives and the AppKit framework. XcodeGen owns the real iOS target
//   (see project.yml) and picks up shared sources from this directory.
//   Tickets 0122/0123/0124 will migrate more surfaces off AppKit; when the
//   runtime surface is cross-platform, this file will grow an iOS target.
let package = Package(
    name: "SmithersGUI",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
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
                "ios",
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
                ".github",
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
                .unsafeFlags(
                    [
                        "-Lghostty/macos/GhosttyKit.xcframework/macos-arm64",
                        "-Llibsmithers/zig-out/lib",
                        "-Llibsmithers",
                    ],
                    .when(platforms: [.macOS])
                ),
                .unsafeFlags(
                    [
                        "-lghostty-fat",
                        "-lsmithers",
                    ],
                    .when(platforms: [.macOS])
                ),
                .linkedLibrary("c++", .when(platforms: [.macOS])),
                .linkedLibrary("resolv", .when(platforms: [.macOS])),
                .linkedLibrary("z", .when(platforms: [.macOS])),
                .linkedLibrary("bz2", .when(platforms: [.macOS])),
                .linkedLibrary("sqlite3", .when(platforms: [.macOS])),
                .linkedFramework("Security", .when(platforms: [.macOS])),
                .linkedFramework("SystemConfiguration", .when(platforms: [.macOS])),
                .linkedFramework("Metal", .when(platforms: [.macOS])),
                .linkedFramework("MetalKit", .when(platforms: [.macOS])),
                .linkedFramework("QuartzCore", .when(platforms: [.macOS])),
                .linkedFramework("CoreGraphics", .when(platforms: [.macOS])),
                .linkedFramework("CoreText", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("WebKit", .when(platforms: [.macOS])),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
                .linkedFramework("Foundation", .when(platforms: [.macOS])),
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
