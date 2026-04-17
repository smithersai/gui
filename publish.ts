#!/usr/bin/env bun
import { $ } from "bun";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const ROOT = import.meta.dir;
const SCHEME = "SmithersGUI";
const CONFIG = "Release";
const BUILD_DIR = join(ROOT, "build");
const ARCHIVE = join(BUILD_DIR, `${SCHEME}.xcarchive`);
const EXPORT_DIR = join(BUILD_DIR, "export");
const DMG_PATH = join(BUILD_DIR, `${SCHEME}.dmg`);
const ZIP_PATH = join(BUILD_DIR, `${SCHEME}.zip`);

const args = new Set(Bun.argv.slice(2));
const skipRust = args.has("--skip-rust");
const skipNotarize = args.has("--no-notarize");
const skipUpload = args.has("--no-upload");

const APPLE_ID = process.env.APPLE_ID;
const TEAM_ID = process.env.APPLE_TEAM_ID;
const APP_PW = process.env.APPLE_APP_PASSWORD;
const SIGN_IDENTITY = process.env.CODE_SIGN_IDENTITY ?? "Developer ID Application";

// Detect whether a Developer ID cert is actually installed
const identities = await $`security find-identity -v -p codesigning`.text().catch(() => "");
const hasDeveloperID = identities.includes("Developer ID Application");
const canNotarize = !!(APPLE_ID && TEAM_ID && APP_PW);

const mode = hasDeveloperID ? "signed" : "unsigned";
console.log(`\n=== Publish mode: ${mode}${canNotarize && !skipNotarize ? " + notarize" : ""} ===\n`);

// --- 1. Clean
rmSync(BUILD_DIR, { recursive: true, force: true });
mkdirSync(BUILD_DIR, { recursive: true });

// --- 2. Rust codex-ffi
if (!skipRust) {
  console.log("→ Building codex-ffi (release)...");
  await $`cargo build -p codex-ffi --release`.cwd(join(ROOT, "codex/codex-rs"));
}

// --- 3. Regenerate Xcode project from project.yml
console.log("→ Regenerating Xcode project...");
await $`xcodegen generate`.cwd(ROOT);

// --- 4. Archive
console.log("→ Archiving...");
const archiveArgs = [
  "-project", `${SCHEME}.xcodeproj`,
  "-scheme", SCHEME,
  "-configuration", CONFIG,
  "-archivePath", ARCHIVE,
  "-destination", "generic/platform=macOS",
  "archive",
  "ARCHS=arm64",
  "ONLY_ACTIVE_ARCH=NO",
  "CODE_SIGN_STYLE=Manual",
];
if (hasDeveloperID) {
  archiveArgs.push(`CODE_SIGN_IDENTITY=${SIGN_IDENTITY}`);
  if (TEAM_ID) archiveArgs.push(`DEVELOPMENT_TEAM=${TEAM_ID}`);
  archiveArgs.push("ENABLE_HARDENED_RUNTIME=YES");
  archiveArgs.push("OTHER_CODE_SIGN_FLAGS=--options=runtime");
} else {
  archiveArgs.push("CODE_SIGN_IDENTITY=-");
  archiveArgs.push("CODE_SIGNING_REQUIRED=NO");
  archiveArgs.push("CODE_SIGNING_ALLOWED=NO");
}
await $`xcodebuild ${archiveArgs}`.cwd(ROOT);

// --- 5. Export
console.log("→ Exporting...");
const exportPlist = join(BUILD_DIR, "ExportOptions.plist");
const method = hasDeveloperID ? "developer-id" : "mac-application";
const teamBlock = hasDeveloperID && TEAM_ID ? `<key>teamID</key><string>${TEAM_ID}</string>` : "";
writeFileSync(exportPlist, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>${method}</string>
  <key>signingStyle</key><string>manual</string>
  ${teamBlock}
</dict></plist>
`);

if (hasDeveloperID) {
  await $`xcodebuild -exportArchive -archivePath ${ARCHIVE} -exportPath ${EXPORT_DIR} -exportOptionsPlist ${exportPlist}`;
} else {
  // Unsigned path: -exportArchive refuses without a cert, so just copy the .app out
  mkdirSync(EXPORT_DIR, { recursive: true });
  await $`cp -R ${ARCHIVE}/Products/Applications/${SCHEME}.app ${EXPORT_DIR}/`;
}

const APP_PATH = join(EXPORT_DIR, `${SCHEME}.app`);
if (!existsSync(APP_PATH)) throw new Error(`App bundle missing at ${APP_PATH}`);

// --- 6. Notarize + staple
if (hasDeveloperID && canNotarize && !skipNotarize) {
  console.log("→ Zipping for notarization...");
  const notarizeZip = join(BUILD_DIR, "notarize.zip");
  await $`ditto -c -k --keepParent ${APP_PATH} ${notarizeZip}`;

  console.log("→ Submitting to Apple notary service (this takes a few minutes)...");
  await $`xcrun notarytool submit ${notarizeZip} --apple-id ${APPLE_ID!} --team-id ${TEAM_ID!} --password ${APP_PW!} --wait`;

  console.log("→ Stapling ticket...");
  await $`xcrun stapler staple ${APP_PATH}`;
} else if (hasDeveloperID) {
  console.log("⚠ Skipping notarization (set APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD to enable).");
}

// --- 7. Package
console.log("→ Packaging...");
try {
  await $`hdiutil create -volname ${SCHEME} -srcfolder ${APP_PATH} -ov -format UDZO ${DMG_PATH}`;
  console.log(`\n✓ DMG:  ${DMG_PATH}`);
} catch {
  await $`ditto -c -k --keepParent ${APP_PATH} ${ZIP_PATH}`;
  console.log(`\n✓ ZIP:  ${ZIP_PATH}`);
}
console.log(`✓ App:  ${APP_PATH}`);

// --- 8. Upload to Cloudflare R2 via alchemy
if (!skipUpload) {
  console.log("\n→ Deploying to get.smithers.sh via alchemy...");
  await $`bun ./alchemy.run.ts`.cwd(ROOT);
}

if (!hasDeveloperID) {
  console.log("\nNote: unsigned build. Users will need to right-click → Open the first time.");
  console.log("Install a 'Developer ID Application' cert and re-run to get a signed build.");
}
