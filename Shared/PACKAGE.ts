import { Smithers as S } from "@smthrs/targets"

// The hermetic SwiftPM package: SmithersAuth, SmithersFlags, SmithersRuntime,
// SmithersStore and SmithersE2ESupport, without CGhosttyKit or libsmithers.
// Package.swift is an input.
const sources = S.Filegroup({
  srcs: [S.glob("**", { exclude: [".build/**", "PACKAGE.ts"] })]
})

// Apple frameworks only (Security, AuthenticationServices, CryptoKit), so the
// target runs on macOS hosts and wildcard selections omit it on Linux. A cold
// build takes about ten minutes, so it is exclusive: run it with
// `smthrs test //Shared:test` or `smthrs ci //... --include-exclusive`.
// SwiftPM keeps its incremental state in Shared/.build (a workspace host
// directory).
const test = S.Shell.Test({
  bin: S.Host.bin("swift"),
  tools: [S.Host.bin("xcrun")],
  args: ["test", "--package-path", "Shared"],
  hosts: ["darwin"],
  exclusive: true,
  sandbox: "none",
  timeout: "40m",
  data: [sources]
})

export const Package = S.Package({
  targets: { sources, test }
})
