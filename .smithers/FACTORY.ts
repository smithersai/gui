/**
 * The factory that develops smithersai/gui (https://smithers.sh/smithersai/gui):
 * featured flows, Dispatcher rules, GitHub policy, and the app home. Projected
 * into .smithers/factory.json and .smithers/home.json by
 * //.smithers:factory-write and checked by //.smithers:factory-check.
 *
 * The Smithers 0.x workflows in .smithers/workflows/ (which the GUI's own
 * workflow views list) are separate and unchanged.
 */
import { Smithers as S } from "@smthrs/targets"

export const review = S.Flow({
  flow: "checks/review",
  featured: true,
  summary: "Review changes for Swift/Zig C ABI ownership, SwiftUI platform guards, OAuth and Keychain safety, and build drift."
})

export const issueRepro = S.Flow({
  flow: "issue/repro",
  featured: true,
  summary: "Reproduce a SmithersGUI, iOS, or libsmithers defect with a minimal failing test or command before planning a fix."
})

export const issuePoc = S.Flow({
  flow: "issue/poc",
  featured: true,
  summary: "Implement a bounded fix with a focused Zig or Swift regression and the affected smthrs targets green."
})

export const ticketVerify = S.Flow({
  flow: "tickets/verify",
  featured: true,
  summary: "Check a .smithers/tickets ticket's acceptance criteria against the code and tests: shipped, partial, or missing."
})

export const prTriage = S.Flow({
  flow: "pr-triage",
  featured: true,
  summary: "Assess pull request readiness from its diff and CI evidence without executing untrusted PR code."
})

export const factory = S.Factory({
  summary: "SmithersGUI: native macOS and iOS client for Smithers, with incremental Zig and Swift checks, C ABI review, and ticket verification.",
  flows: [review, issueRepro, issuePoc, ticketVerify, prTriage],
  on: {},
  github: S.Github.Policy({
    mirror: "pull",
    issues: "read",
    changes: "send-upstream",
    maintainers: ["roninjin10"],
    protectedPaths: [
      "libsmithers/include/smithers.h",
      "libsmithers/src/apprt/embedded.zig",
      "Shared/Sources/SmithersAuth",
      "project.yml",
      "Package.swift",
      "alchemy.run.ts",
      ".github/workflows/ios-testflight.yml"
    ]
  })
})

export const home = S.Factory.Home({
  blocks: [
    {
      type: "text",
      title: "SmithersGUI factory",
      text: "Native SwiftUI client for Smithers workflows, agent sessions, terminals, and tickets on macOS 14+ and iOS 17+. The Zig core (libsmithers) exposes a C ABI to Swift; Ghostty renders terminals. smthrs ci runs the Zig build, tests, and format check, the workflow helper tests, and repository hygiene with a local-first cache synced through build.smithers.sh."
    },
    {
      type: "prompt",
      title: "Ask about SmithersGUI",
      placeholder: "Describe a GUI, iOS, or libsmithers bug or change…"
    },
    {
      type: "flows",
      title: "Review, reproduce, and verify tickets"
    },
    {
      type: "links",
      links: [
        { label: "Repository", url: "https://github.com/smithersai/gui" },
        { label: "CI", url: "https://github.com/smithersai/gui/actions/workflows/ci.yml" },
        { label: "Download SmithersGUI.dmg", url: "https://download.smithers.sh/SmithersGUI.dmg" },
        { label: "libsmithers C ABI contract", url: "https://github.com/smithersai/gui/blob/main/docs/libsmithers-contract.md" }
      ]
    }
  ]
})
