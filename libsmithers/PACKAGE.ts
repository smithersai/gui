import { Smithers as S } from "@smthrs/targets"
import { fileURLToPath } from "node:url"

// The Zig core's input closure. bench/ and fuzz/ are separate Zig projects
// with their own build.zig.zon, and scripts/ holds the iOS xcframework
// script; the build and tests read none of them.
const sources = S.Filegroup({
  srcs: [
    S.glob("**", {
      exclude: [".zig-cache/**", "zig-out/**", "bench/**", "fuzz/**", "scripts/**", "PACKAGE.ts", "README.md"]
    })
  ]
})

// Zig caches stay under the workspace cache so a cold checkout and CI start
// from the same place, and so `rm -rf .smithers/cache` resets everything.
const env = {
  ZIG_GLOBAL_CACHE_DIR: fileURLToPath(new URL("../.smithers/cache/tools/zig/global", import.meta.url)),
  ZIG_LOCAL_CACHE_DIR: fileURLToPath(new URL("../.smithers/cache/tools/zig/local", import.meta.url))
}

// Each command changes into libsmithers/ first, like `zig build libsmithers`
// in the root build.zig: tests open files relative to the working directory
// (src/session/fd_passing.zig opens build.zig), and that must be this
// package's build.zig, an input of every target here.
const zig = (
  timeout: "2m" | "5m" | "30m",
  command: string,
  data: ReadonlyArray<typeof sources | ReturnType<typeof S.file>> = [sources]
) =>
  S.Shell.Test({
    shell: `cd libsmithers && ${command}`,
    tools: [S.Host.bin("zig")],
    env,
    sandbox: "none",
    timeout,
    data
  })

// libsmithers.a, smithers.h and the session daemon/connect helpers. Debug,
// like `zig build libsmithers`, because project.yml bundles these binaries
// from libsmithers/zig-out/bin.
const build = S.Shell.Build({
  shell: "cd libsmithers && zig build -p zig-out",
  tools: [S.Host.bin("zig")],
  env,
  sandbox: "none",
  timeout: "30m",
  data: [sources],
  outDirs: ["//libsmithers/zig-out"]
})

// Every libsmithers suite: C ABI e2e, unit, daemon, session-connect, devtools
// stream, core FFI smoke, and the real-transport tests (no-ops unless
// POC_ELECTRIC_STACK=1).
const test = zig("30m", "zig build test --summary all")

// Unit tests inside build.zig itself (macOS SDK libsqlite3 slice selection).
const testBuildScript = zig("5m", "zig test build.zig", [S.file("build.zig")])

const fmt = zig("2m", "zig fmt --check build.zig src test cli")

export const Package = S.Package({
  targets: {
    sources,
    build,
    test,
    "test-build-script": testBuildScript,
    fmt
  }
})
