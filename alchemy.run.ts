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
const notarize = signed && APPLE_ID && TEAM && PW && !has("--no-notarize");

if (!has("--skip-build")) await build();

const app = await alchemy("smithers-gui");
export const releases = await R2Bucket("smithers-gui-releases", {
  name: "smithers-gui-releases",
  domains: "get.smithers.sh",
});

if (!has("--no-upload")) await upload();
await app.finalize();

// ---------- build ----------

async function build() {
  console.log(`\n=== ${signed ? "signed" : "unsigned"}${notarize ? " + notarize" : ""} ===\n`);
  rmSync(BUILD, { recursive: true, force: true });
  mkdirSync(BUILD, { recursive: true });

  if (!has("--skip-rust")) {
    console.log("→ codex-ffi");
    await $`cargo build -p codex-ffi --release`.cwd(join(ROOT, "codex/codex-rs"));
  }

  console.log("→ xcodegen");
  await $`xcodegen generate`.cwd(ROOT);

  console.log("→ archive");
  const signArgs = signed
    ? [
        `CODE_SIGN_IDENTITY=${process.env.CODE_SIGN_IDENTITY ?? "Developer ID Application"}`,
        ...(TEAM ? [`DEVELOPMENT_TEAM=${TEAM}`] : []),
        "ENABLE_HARDENED_RUNTIME=YES",
        "OTHER_CODE_SIGN_FLAGS=--options=runtime",
      ]
    : ["CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGNING_ALLOWED=NO"];
  await $`xcodebuild -project ${SCHEME}.xcodeproj -scheme ${SCHEME} -configuration Release -archivePath ${ARCHIVE} -destination generic/platform=macOS archive ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Manual ${signArgs}`.cwd(ROOT);

  console.log("→ export");
  if (signed) {
    const plist = join(BUILD, "ExportOptions.plist");
    writeFileSync(plist, exportPlist(TEAM));
    await $`xcodebuild -exportArchive -archivePath ${ARCHIVE} -exportPath ${join(BUILD, "export")} -exportOptionsPlist ${plist}`;
  } else {
    mkdirSync(join(BUILD, "export"), { recursive: true });
    await $`cp -R ${ARCHIVE}/Products/Applications/${SCHEME}.app ${join(BUILD, "export")}/`;
  }

  if (notarize) {
    console.log("→ notarize (takes a few minutes)");
    const zip = join(BUILD, "notarize.zip");
    await $`ditto -c -k --keepParent ${APP} ${zip}`;
    await $`xcrun notarytool submit ${zip} --apple-id ${APPLE_ID!} --team-id ${TEAM!} --password ${PW!} --wait`;
    await $`xcrun stapler staple ${APP}`;
  }

  console.log("→ dmg");
  await $`hdiutil create -volname ${SCHEME} -srcfolder ${APP} -ov -format UDZO ${DMG}`;
  console.log(`✓ ${DMG}`);
}

async function upload() {
  if (!existsSync(DMG)) return console.log(`(no DMG at ${DMG} — skipping)`);
  const version = process.env.RELEASE_VERSION ?? "latest";
  const body = await readFile(DMG);
  const opts = { httpMetadata: { contentType: "application/x-apple-diskimage" } };
  const keys = [`${SCHEME}.dmg`, `releases/${version}/${SCHEME}.dmg`];

  console.log(`\n→ uploading ${(statSync(DMG).size / 1024 / 1024).toFixed(1)}MB`);
  for (const key of keys) await releases.put(key, body, opts);

  console.log("\n✓ live at:");
  for (const key of keys) console.log(`  https://get.smithers.sh/${key}`);
  if (!signed) console.log("\n⚠ unsigned — users must right-click → Open on first launch");
}

function exportPlist(team?: string) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  ${team ? `<key>teamID</key><string>${team}</string>` : ""}
</dict></plist>`;
}
