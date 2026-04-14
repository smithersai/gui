// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SmithersGUI",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(
            name: "CCodexFFI",
            path: "CCodexFFI"
        ),
        .executableTarget(
            name: "SmithersGUI",
            dependencies: ["CCodexFFI"],
            path: ".",
            exclude: [
                "codex",
                "CCodexFFI",
                "codex-ffi.h",
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/Users/williamcory/gui/codex/codex-rs/target/release",
                ]),
                .linkedLibrary("resolv"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
            ]
        )
    ]
)
