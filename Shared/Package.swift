// swift-tools-version: 5.9
//
// Standalone SwiftPM package for the shared OAuth2/PKCE/Keychain module
// (ticket 0109). Keeps the test loop fast and hermetic — `swift test` here
// does NOT pull in CGhosttyKit / libsmithers / the rest of the SmithersGUI
// target graph, so tests can run in any environment.
//
// The top-level Package.swift also exposes `SmithersAuth` as a library
// product pointing at the same sources, so the XcodeGen iOS + macOS
// targets link the one canonical implementation.

import PackageDescription

let package = Package(
    name: "SmithersShared",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "SmithersAuth", targets: ["SmithersAuth"]),
        .library(name: "SmithersRuntime", targets: ["SmithersRuntime"]),
    ],
    targets: [
        .target(
            name: "SmithersAuth",
            path: "Sources/SmithersAuth",
            exclude: ["README.md"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("AuthenticationServices"),
                .linkedFramework("CryptoKit"),
            ]
        ),
        .testTarget(
            name: "SmithersAuthTests",
            dependencies: ["SmithersAuth"],
            path: "Tests/SmithersAuthTests"
        ),
        // SmithersRuntime — thin Swift wrapper around the 0120 libsmithers-core
        // FFI. The #if canImport(CSmithersKit) guard in the source file means
        // the standalone SwiftPM build (no C module) compiles the type-safe
        // Swift surfaces but skips FFI-calling code. The full macOS/iOS app
        // targets (via the root Package.swift / Xcode project) bind the real
        // C module and get the runtime wiring.
        .target(
            name: "SmithersRuntime",
            path: "Sources/SmithersRuntime"
        ),
        .testTarget(
            name: "SmithersRuntimeTests",
            dependencies: ["SmithersRuntime"],
            path: "Tests/SmithersRuntimeTests"
        ),
    ]
)
