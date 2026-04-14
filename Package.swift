// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SmithersGUI",
    platforms: [.macOS(.v14)],
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
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/Users/williamcory/gui/codex/codex-rs/target/release",
                    "-L/Users/williamcory/gui/ghostty/macos/GhosttyKit.xcframework/macos-arm64",
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
                .linkedFramework("Carbon"),
                .linkedFramework("Foundation"),
            ]
        )
    ]
)
