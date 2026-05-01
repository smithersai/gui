#!/usr/bin/env bun
import alchemy from "alchemy";
import { R2Bucket } from "alchemy/cloudflare";
import { $ } from "bun";
import { existsSync, mkdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

const ROOT = import.meta.dir;
const SCHEME = "SmithersGUI";
const BUILD = join(ROOT, "build");
const ARCHIVE = join(BUILD, `${SCHEME}.xcarchive`);
const APP = join(BUILD, "export", `${SCHEME}.app`);
const DMG = join(BUILD, `${SCHEME}.dmg`);

const flags = new Set(Bun.argv.slice(2));
const has = (f: string) => flags.has(f);

const { APPLE_ID, APPLE_TEAM_ID: TEAM, APPLE_APP_PASSWORD: PW } = process.env;
const ids = await $`security find-identity -v -p codesigning`.text().catch(() => "");
const signed = ids.includes("Developer ID Application");

if (!signed || !APPLE_ID || !TEAM || !PW) {
  console.error("error: notarized release requires:");
  console.error("  - Developer ID Application identity in keychain");
  console.error("  - APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD env vars");
  process.exit(1);
}

if (!has("--skip-build")) await build();

const app = await alchemy("smithers-gui");
export const releases = await R2Bucket("smithers-gui-releases", {
  name: "smithers-gui-releases",
  devDomain: true,
  adopt: true,
});

if (!has("--no-upload")) await upload();
if (!has("--no-vercel")) await deployVercelRedirect();
await app.finalize();

// ---------- build ----------

async function build() {
  console.log(`\n=== signed + notarize ===\n`);
  rmSync(BUILD, { recursive: true, force: true });
  mkdirSync(BUILD, { recursive: true });

  console.log("→ xcodegen");
  await $`xcodegen generate`.cwd(ROOT);

  console.log("→ archive");
  const identity = process.env.CODE_SIGN_IDENTITY ?? "Developer ID Application";
  await $`xcodebuild -project ${SCHEME}.xcodeproj -scheme ${SCHEME} -configuration Release -archivePath ${ARCHIVE} -destination generic/platform=macOS archive ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=${identity} DEVELOPMENT_TEAM=${TEAM} ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--options=runtime`.cwd(ROOT);

  console.log("→ export");
  const plist = join(BUILD, "ExportOptions.plist");
  writeFileSync(plist, exportPlist(TEAM));
  await $`xcodebuild -exportArchive -archivePath ${ARCHIVE} -exportPath ${join(BUILD, "export")} -exportOptionsPlist ${plist}`;

  // Helper binaries bundled under Contents/Resources/ are opaque to xcodebuild's
  // signing, so the hardened-runtime flag never reaches them. Re-sign them
  // (deepest first), then re-seal the parent .app, before submitting.
  for (const helper of ["smithers-session-daemon", "smithers-session-connect"]) {
    const path = join(APP, "Contents", "Resources", helper);
    if (existsSync(path)) {
      await $`codesign --force --options runtime --timestamp --sign ${identity} ${path}`;
    }
  }
  await $`codesign --force --options runtime --timestamp --sign ${identity} ${APP}`;

  console.log("→ notarize (takes a few minutes)");
  const zip = join(BUILD, "notarize.zip");
  await $`ditto -c -k --keepParent ${APP} ${zip}`;
  await $`xcrun notarytool submit ${zip} --apple-id ${APPLE_ID} --team-id ${TEAM} --password ${PW} --wait`;
  await $`xcrun stapler staple ${APP}`;

  console.log("→ dmg");
  const staging = join(BUILD, "dmg-staging");
  rmSync(staging, { recursive: true, force: true });
  mkdirSync(staging, { recursive: true });
  await $`cp -R ${APP} ${staging}/`;
  await $`ln -s /Applications ${staging}/Applications`;
  await $`hdiutil create -volname ${SCHEME} -srcfolder ${staging} -ov -format UDZO ${DMG}`;
  rmSync(staging, { recursive: true, force: true });
  console.log(`✓ ${DMG}`);
}

async function upload() {
  if (!existsSync(DMG)) return console.log(`(no DMG at ${DMG} — skipping)`);
  const version = process.env.RELEASE_VERSION ?? "latest";
  const body = await readFile(DMG);
  const dmgOpts = { httpMetadata: { contentType: "application/x-apple-diskimage" } };
  const dmgKeys = [`${SCHEME}.dmg`, `releases/${version}/${SCHEME}.dmg`];

  console.log(`\n→ uploading ${(statSync(DMG).size / 1024 / 1024).toFixed(1)}MB`);
  for (const key of dmgKeys) await releases.put(key, body, dmgOpts);

  const base = releases.devDomain ? `https://${releases.devDomain}` : null;
  const url = (key: string) => (base ? `${base}/${key}` : `(r2://smithers-gui-releases/${key})`);
  console.log("\n✓ uploaded:");
  for (const key of dmgKeys) console.log(`  ${url(key)}`);
  console.log("\n  public:    https://download.smithers.sh/SmithersGUI.dmg");
}

async function deployVercelRedirect() {
  const script = join(ROOT, "scripts/deploy-download-redirect.ts");
  if (!existsSync(script)) return;
  console.log("\n→ vercel: refresh download.smithers.sh redirect");
  await $`bun ${script}`.nothrow();
}

function exportPlist(team: string) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>${team}</string>
</dict></plist>`;
}
