#!/usr/bin/env bun
import alchemy from "alchemy";
import { R2Bucket } from "alchemy/cloudflare";
import { existsSync, statSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { basename, join } from "node:path";

const app = await alchemy("smithers-gui");

export const releases = await R2Bucket("smithers-gui-releases", {
  name: "smithers-gui-releases",
  domains: "get.smithers.sh",
});

// Upload the latest DMG if a local build exists. Running `bun alchemy.run.ts`
// after `bun publish.ts` publishes the fresh build.
const DMG = join(import.meta.dir, "build/SmithersGUI.dmg");
if (existsSync(DMG)) {
  const version = process.env.RELEASE_VERSION ?? "latest";
  const size = (statSync(DMG).size / 1024 / 1024).toFixed(1);
  const body = await readFile(DMG);

  const versionedKey = `releases/${version}/${basename(DMG)}`;
  const latestKey = `SmithersGUI.dmg`;

  console.log(`→ Uploading ${size}MB to r2://${versionedKey}`);
  await releases.put(versionedKey, body, { httpMetadata: { contentType: "application/x-apple-diskimage" } });

  console.log(`→ Updating r2://${latestKey}`);
  await releases.put(latestKey, body, { httpMetadata: { contentType: "application/x-apple-diskimage" } });

  console.log(`\n✓ Live at:`);
  console.log(`  https://get.smithers.sh/${latestKey}`);
  console.log(`  https://get.smithers.sh/${versionedKey}`);
} else {
  console.log(`(no DMG at ${DMG} — skipping upload. Run \`bun publish.ts\` first.)`);
}

await app.finalize();
