import { Smithers as S } from "@smthrs/targets"

// Globs stay package-scoped even with a // prefix, so every root-anchored
// group sets cwd: "//". Each group is the narrow input closure of one check:
// editing Swift or Zig sources never invalidates these targets.
const hygieneSources = S.Filegroup({
  cwd: "//",
  srcs: [
    S.file("//.zigversion"),
    S.file("//libsmithers/build.zig"),
    S.file("//linux/build.zig.zon"),
    S.glob("//.github/workflows/*.yml"),
    S.glob("//.github/workflows/*.yaml"),
    S.glob("//ios/scripts/*.sh"),
    S.file("//macos/scripts/run-e2e.sh"),
    S.file("//libsmithers/scripts/build-ios-xcframework.sh"),
    S.file("//libsmithers/fuzz/run.sh")
  ]
})

// The factory declaration, its projections, and every flow; never engine
// state, caches, reports, or the legacy workflow package's dependencies.
const factorySources = S.Filegroup({
  srcs: [
    S.file("FACTORY.ts"),
    S.file("factory.json"),
    S.file("home.json"),
    S.glob("flows/**")
  ]
})

// The legacy Smithers 0.x workflow helpers the GUI's workflow views read.
// Only the dependency-free modules: agents.ts needs smithers-orchestrator.
// Bun reads the package's tsconfig.json and package.json when it loads them.
const workflowHelpers = S.Filegroup({
  srcs: [
    S.file("tsconfig.json"),
    S.file("package.json"),
    S.file("parsing.ts"),
    S.file("routing.ts"),
    S.file("tests/parsing.test.ts"),
    S.file("tests/routing.test.ts")
  ]
})

const hygiene = S.Shell.Test({
  bin: S.Host.bin("node"),
  tools: [S.Host.bin("sh"), S.Host.bin("bash")],
  args: ["--test", ".smithers/checks/repo-hygiene.mjs"],
  sandbox: "none",
  timeout: "2m",
  data: [hygieneSources, factorySources, S.file("checks/repo-hygiene.mjs")]
})

// Runs from the repository root so .smithers/bunfig.toml (whose preload
// imports smithers-orchestrator) is not loaded; these modules need no install.
const workflowsTest = S.Shell.Test({
  bin: S.Host.bin("bun"),
  args: ["test", "./.smithers/tests/parsing.test.ts", "./.smithers/tests/routing.test.ts"],
  sandbox: "none",
  timeout: "2m",
  data: [workflowHelpers]
})

export const Package = S.Package({
  targets: {
    "hygiene-sources": hygieneSources,
    "factory-sources": factorySources,
    "workflow-helpers": workflowHelpers,
    "factory-write": S.FactoryProjection({ mode: "write" }),
    "factory-check": S.FactoryProjection({ mode: "check" }),
    hygiene,
    "workflows-test": workflowsTest
  }
})
