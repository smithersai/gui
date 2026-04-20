#!/usr/bin/env bun
// Sign the release DMG with the secp256k1 key stored in macOS Keychain.
// Writes <dmg>.sha256 and <dmg>.sig next to the DMG and prints the signer address.
//
// Usage: bun scripts/sign-dmg.ts [path/to/SmithersGUI.dmg]
import { $ } from "bun";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { join, dirname } from "node:path";

const CAST = process.env.CAST ?? `${process.env.HOME}/.foundry/bin/cast`;
const SERVICE = "smithers-gui-signing";
const ACCOUNT = "signing-key";

const ROOT = join(import.meta.dir, "..");
const DEFAULT_DMG = join(ROOT, "build", "SmithersGUI.dmg");
const DMG = process.argv[2] ?? DEFAULT_DMG;
const ADDR_FILE = join(import.meta.dir, ".signing-address");

if (!existsSync(DMG)) {
  console.error(`DMG not found: ${DMG}`);
  process.exit(1);
}
if (!existsSync(ADDR_FILE)) {
  console.error(`signer address file not found: ${ADDR_FILE}`);
  console.error(`run: bun scripts/init-signing-key.ts`);
  process.exit(1);
}

const address = readFileSync(ADDR_FILE, "utf8").trim();
const sha = createHash("sha256").update(readFileSync(DMG)).digest("hex");
const shaFile = `${DMG}.sha256`;
const sigFile = `${DMG}.sig`;
writeFileSync(shaFile, `${sha}  ${DMG.split("/").pop()}\n`);

const key = await $`security find-generic-password -s ${SERVICE} -a ${ACCOUNT} -w`.quiet().text();
const signature = (await $`${CAST} wallet sign --private-key ${key.trim()} ${"0x" + sha}`.quiet().text()).trim();

writeFileSync(sigFile, signature + "\n");

console.log(`signer:    ${address}`);
console.log(`sha256:    ${sha}`);
console.log(`signature: ${signature}`);
console.log(`wrote:     ${shaFile}`);
console.log(`wrote:     ${sigFile}`);

export { address, sha, signature, shaFile, sigFile };
