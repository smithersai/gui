#!/usr/bin/env bun
// Generate a fresh secp256k1 keypair and store the private key in macOS Keychain.
// Only the public address is printed; the private key never touches stdout/logs.
//
// Keychain entry:  service=smithers-gui-signing, account=signing-key
// Public address:  written to scripts/.signing-address (commit this)
import { $ } from "bun";
import { writeFileSync } from "node:fs";
import { join } from "node:path";

const CAST = process.env.CAST ?? `${process.env.HOME}/.foundry/bin/cast`;
const SERVICE = "smithers-gui-signing";
const ACCOUNT = "signing-key";
const ADDR_FILE = join(import.meta.dir, ".signing-address");

const exists = await $`security find-generic-password -s ${SERVICE} -a ${ACCOUNT}`.quiet().nothrow();
if (exists.exitCode === 0) {
  console.error(`Keychain entry already exists for service=${SERVICE} account=${ACCOUNT}.`);
  console.error("Delete it first if you want to rotate:");
  console.error(`  security delete-generic-password -s ${SERVICE} -a ${ACCOUNT}`);
  process.exit(1);
}

const json = await $`${CAST} wallet new --json`.quiet().text();
const parsed = JSON.parse(json);
const entry = Array.isArray(parsed) ? parsed[0] : parsed;
const address: string = entry.address;
const privateKey: string = entry.private_key ?? entry.privateKey;

if (!address || !privateKey) {
  console.error("failed to parse `cast wallet new --json` output");
  process.exit(1);
}

await $`security add-generic-password \
  -s ${SERVICE} -a ${ACCOUNT} \
  -l ${"Smithers GUI release signing key"} \
  -D ${"secp256k1 private key"} \
  -w ${privateKey}`.quiet();

writeFileSync(ADDR_FILE, address + "\n");

console.log(`Stored in Keychain: service=${SERVICE} account=${ACCOUNT}`);
console.log(`Signer address:    ${address}`);
console.log(`Wrote:             ${ADDR_FILE}`);
