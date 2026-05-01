#!/usr/bin/env bun
// Deploy the download.smithers.sh → R2 redirect project to Vercel.
// Idempotent — safe to run on every release. Updates the prod alias to
// match whatever's in vercel/download/vercel.json right now.
import { $ } from "bun";
import { existsSync } from "node:fs";
import { join } from "node:path";

const ROOT = join(import.meta.dir, "..");
const DIR = join(ROOT, "vercel/download");
const SCOPE = process.env.VERCEL_SCOPE ?? "evmts";

if (!existsSync(join(DIR, "vercel.json"))) {
  console.error(`vercel.json not found at ${DIR}`);
  process.exit(1);
}
if (!existsSync(join(DIR, ".vercel/project.json"))) {
  console.error(`${DIR}/.vercel/project.json missing — run once:`);
  console.error(`  cd ${DIR} && vercel link --yes --project smithers-download --scope ${SCOPE}`);
  process.exit(1);
}

console.log("→ deploying download.smithers.sh redirect");
await $`vercel deploy --prod --yes --scope ${SCOPE}`.cwd(DIR);
console.log("✓ download.smithers.sh deployment updated");
