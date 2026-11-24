// smthrs discovers this file. Do not add WORKSPACE.smithers beside it:
// smthrs 1.0.0-rc.18 discovers both names and refuses a duplicate workspace.
import { Smithers as S } from "@smthrs/targets"

export const Workspace = S.Workspace("smithersai-gui", {
  repository: "smithersai/gui",
  cache: S.Cache({
    directory: ".smithers/cache",
    // SwiftPM's incremental build state for //Shared:test. Zig caches live
    // under .smithers/cache/tools/zig (see libsmithers/PACKAGE.ts).
    hostDirectories: ["Shared/.build"],
    // Results cache locally under .smithers/cache and sync through
    // build.smithers.sh when the tokens are set (locally or in GitHub Actions).
    remote: S.RemoteCache.make({
      endpoint: "https://build.smithers.sh",
      read: S.Secret("SMITHERS_CACHE_READ_TOKEN"),
      write: S.Secret("SMITHERS_CACHE_WRITE_TOKEN")
    })
  }),
  host: S.Host({ bins: ["sh", "bash", "node", "bun", "zig", "swift", "xcrun"] }),
  discovery: {
    // ghostty is a large submodule; poc/ holds standalone prototypes with their
    // own build.zig files; the rest are tool output and runtime state.
    prune: [
      "ghostty",
      "poc",
      "vendor",
      "tmux",
      "node_modules",
      ".build",
      ".zig-cache",
      "zig-out",
      ".worktrees",
      ".flows",
      ".alchemy",
      "SmithersGUI.xcodeproj",
      ".smithers/cache",
      ".smithers/reports",
      ".smithers/pg",
      ".smithers/executions",
      ".smithers/node_modules"
    ]
  }
})
