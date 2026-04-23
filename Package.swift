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
    products: [
        // Exposed so the iOS XcodeGen target can consume the shared auth
        // module. Cross-platform (iOS + macOS). See ticket 0109.
        .library(name: "SmithersAuth", targets: ["SmithersAuth"]),
        // Ticket 0124: shared observable store layer over SmithersRuntime.
        .library(name: "SmithersStore", targets: ["SmithersStore"]),
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
        // Ticket 0109. Shared OAuth2/PKCE/Keychain module. Must compile for
        // BOTH macOS and iOS — no AppKit/UIKit imports, only Foundation,
        // CryptoKit, Security, SwiftUI, AuthenticationServices.
        .target(
            name: "SmithersAuth",
            path: "Shared/Sources/SmithersAuth",
            exclude: ["README.md"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("AuthenticationServices"),
                .linkedFramework("CryptoKit"),
            ]
        ),
        // Tests for SmithersAuth live in the standalone SwiftPM package at
        // `Shared/Package.swift` so `swift test` there can run hermetically
        // without compiling the whole SmithersGUI / CGhosttyKit graph.
        .executableTarget(
            name: "SmithersGUI",
            dependencies: ["CGhosttyKit", "CSmithersKit", "SmithersAuth", "SmithersRuntime", "SmithersStore"],
            path: ".",
            exclude: [
                "ghostty",
                "CGhosttyKit",
                "CSmithersKit",
                "poc",
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
                "Shared",
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

        // ticket/0120 — thin Swift wrapper around the new libsmithers-core FFI.
        // Cross-platform (macOS + iOS) by design; no AppKit / WebKit deps.
        .target(
            name: "SmithersRuntime",
            dependencies: ["CSmithersKit"],
            path: "Shared/Sources/SmithersRuntime",
            linkerSettings: [
                .unsafeFlags(
                    [
                        "-Llibsmithers/zig-out/lib",
                        "-lsmithers",
                    ],
                    .when(platforms: [.macOS])
                ),
                .linkedLibrary("sqlite3", .when(platforms: [.macOS])),
                .linkedLibrary("c++", .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "SmithersRuntimeTests",
            dependencies: ["SmithersRuntime"],
            path: "Shared/Tests/SmithersRuntimeTests"
        ),

        // ticket/0124 — shared observable stores over SmithersRuntime.
        // Cross-platform (macOS + iOS); no AppKit/UIKit/CLI. Views bind
        // via @Published arrays; writes go through the pessimistic
        // dispatcher on `SmithersStore`.
        .target(
            name: "SmithersStore",
            dependencies: ["SmithersRuntime"],
            path: "Shared/Sources/SmithersStore",
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "SmithersStoreTests",
            dependencies: ["SmithersStore"],
            path: "Shared/Tests/SmithersStoreTests"
        ),
    ]
)
