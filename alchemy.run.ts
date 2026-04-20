#!/usr/bin/env bun
import alchemy from "alchemy";
import { R2Bucket } from "alchemy/cloudflare";
import { $ } from "bun";
import { existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
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
  devDomain: true,
  adopt: true,
});

const ethSig = !notarize && !has("--no-eth-sign") ? await ethSign() : null;

if (!has("--no-upload")) await upload();
if (!has("--no-vercel")) await deployVercelRedirect();
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
    : ["CODE_SIGN_IDENTITY=-"];
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
  const dmgOpts = { httpMetadata: { contentType: "application/x-apple-diskimage" } };
  const txtOpts = { httpMetadata: { contentType: "text/plain; charset=utf-8" } };
  const dmgKeys = [`${SCHEME}.dmg`, `releases/${version}/${SCHEME}.dmg`];

  console.log(`\n→ uploading ${(statSync(DMG).size / 1024 / 1024).toFixed(1)}MB`);
  for (const key of dmgKeys) await releases.put(key, body, dmgOpts);

  if (ethSig) {
    const shaBody = await readFile(ethSig.shaFile);
    const sigBody = await readFile(ethSig.sigFile);
    for (const base of dmgKeys) {
      await releases.put(`${base}.sha256`, shaBody, txtOpts);
      await releases.put(`${base}.sig`, sigBody, txtOpts);
    }
  }

  const base = releases.devDomain ? `https://${releases.devDomain}` : null;
  const url = (key: string) => (base ? `${base}/${key}` : `(r2://smithers-gui-releases/${key})`);
  console.log("\n✓ uploaded:");
  for (const key of dmgKeys) console.log(`  ${url(key)}`);
  if (ethSig) {
    for (const key of dmgKeys) {
      console.log(`  ${url(`${key}.sha256`)}`);
      console.log(`  ${url(`${key}.sig`)}`);
    }
    console.log(`\n  signer:    ${ethSig.address}`);
    console.log(`  signature: ${ethSig.signature}`);
  }
  console.log("\n  public:    https://download.smithers.sh/SmithersGUI.dmg");
  if (!signed) {
    console.log(
      "\n⚠ unsigned — first-launch instructions: System Settings → Privacy & Security → 'Open Anyway'",
    );
  }
}

async function deployVercelRedirect() {
  const script = join(ROOT, "scripts/deploy-download-redirect.ts");
  if (!existsSync(script)) return;
  console.log("\n→ vercel: refresh download.smithers.sh redirect");
  await $`bun ${script}`.nothrow();
}

async function ethSign() {
  const addrFile = join(ROOT, "scripts", ".signing-address");
  if (!existsSync(addrFile)) {
    console.log("(no scripts/.signing-address — skipping eth signing; run `bun scripts/init-signing-key.ts`)");
    return null;
  }
  if (!existsSync(DMG)) return null;
  console.log("→ eth-sign DMG");
  await $`bun ${join(ROOT, "scripts/sign-dmg.ts")} ${DMG}`;
  return {
    address: readFileSync(addrFile, "utf8").trim(),
    sha: readFileSync(`${DMG}.sha256`, "utf8").split(/\s+/)[0],
    signature: readFileSync(`${DMG}.sig`, "utf8").trim(),
    shaFile: `${DMG}.sha256`,
    sigFile: `${DMG}.sig`,
  };
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
