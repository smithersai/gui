#!/usr/bin/env bun
import alchemy from "alchemy";
import { R2Bucket } from "alchemy/cloudflare";
import { $ } from "bun";
import { existsSync, mkdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

const ROOT = import.meta.dir;
const SCHEME = "SmithersGUI";
const VOLUME_NAME = "Smithers App";
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

const app = await alchemy("smithers-app");
export const releases = await R2Bucket("smithers-app-releases", {
  name: "smithers-app-releases",
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

  console.log("→ dmg background");
  const bgPng = join(BUILD, "dmg-background.png");
  await makeDmgBackground(bgPng);

  console.log("→ dmg");
  const staging = join(BUILD, "dmg-staging");
  const tmpDmg  = join(BUILD, "tmp-rw.dmg");
  rmSync(staging, { recursive: true, force: true });
  mkdirSync(join(staging, ".background"), { recursive: true });
  await $`cp -R ${APP} ${staging}/`;
  await $`ln -s /Applications ${staging}/Applications`;
  await $`cp ${bgPng} ${join(staging, ".background", "background.png")}`;

  await $`hdiutil create -volname ${VOLUME_NAME} -srcfolder ${staging} -ov -format UDRW -size 120m ${tmpDmg}`;
  rmSync(staging, { recursive: true, force: true });

  const attachOut = await $`hdiutil attach -readwrite -noverify -noautoopen ${tmpDmg}`.text();
  const mountPoint = attachOut.trim().split("\n").at(-1)?.split("\t").at(-1)?.trim() ?? `/Volumes/${VOLUME_NAME}`;

  const appleScript = `
tell application "Finder"
  tell disk "${VOLUME_NAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {160, 100, 800, 500}
    set theViewOptions to icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 100
    set background picture of theViewOptions to (POSIX file "${mountPoint}/.background/background.png" as alias)
    set position of item "${SCHEME}.app" of container window to {180, 195}
    set position of item "Applications" of container window to {460, 195}
    update without registering applications
    delay 2
    close
  end tell
end tell
`;
  const scriptPath = join(BUILD, "configure-dmg.applescript");
  writeFileSync(scriptPath, appleScript);
  await $`osascript ${scriptPath}`.nothrow();
  rmSync(scriptPath, { force: true });

  await $`sync`;
  await $`hdiutil detach ${mountPoint}`;
  await $`hdiutil convert ${tmpDmg} -format UDZO -imagekey zlib-level=9 -o ${DMG}`;
  rmSync(tmpDmg, { force: true });
  console.log(`✓ ${DMG}`);
}

async function makeDmgBackground(outPath: string) {
  // 640 × 400 pt window, @2x PNG (1280 × 800 px).
  // App icon centre: (180, 195) — Applications centre: (460, 195) in window coords.
  // Arrow midpoint: x=320, y=195 from top → CG y = 400-195 = 205.
  const swift = `
import CoreGraphics
import ImageIO
import Foundation

let W = 640, H = 400, scale = 2
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
  data: nil, width: W * scale, height: H * scale,
  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }
ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

// Dark charcoal gradient top → bottom
let gradColors = [CGColor(red:0.18,green:0.18,blue:0.20,alpha:1),
                  CGColor(red:0.11,green:0.11,blue:0.13,alpha:1)] as CFArray
let grad = CGGradient(colorsSpace: cs, colors: gradColors, locations: [0.0, 1.0])!
ctx.drawLinearGradient(grad,
  start: CGPoint(x: W/2, y: H), end: CGPoint(x: W/2, y: 0), options: [])

// Right-pointing arrow at (320, 205) in CG coords
let cx: CGFloat = 320, cy: CGFloat = 205
let shaftW: CGFloat = 52, shaftH: CGFloat = 8, headW: CGFloat = 26, headH: CGFloat = 28
let path = CGMutablePath()
path.addRect(CGRect(x: cx-shaftW/2, y: cy-shaftH/2, width: shaftW, height: shaftH))
path.move(to:    CGPoint(x: cx+shaftW/2,       y: cy+headH/2))
path.addLine(to: CGPoint(x: cx+shaftW/2+headW, y: cy))
path.addLine(to: CGPoint(x: cx+shaftW/2,       y: cy-headH/2))
path.closeSubpath()
ctx.setFillColor(CGColor(red:1,green:1,blue:1,alpha:0.5))
ctx.addPath(path); ctx.fillPath()

guard let img  = ctx.makeImage() else { exit(1) }
let url  = URL(fileURLWithPath: "${outPath}")
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(dest, img,
  [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
guard CGImageDestinationFinalize(dest) else { exit(1) }
`;
  const swiftPath = join(BUILD, "make-dmg-background.swift");
  writeFileSync(swiftPath, swift);
  await $`xcrun swift ${swiftPath}`;
  rmSync(swiftPath, { force: true });
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
  const url = (key: string) => (base ? `${base}/${key}` : `(r2://smithers-app-releases/${key})`);
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
