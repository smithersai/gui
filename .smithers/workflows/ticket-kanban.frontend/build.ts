import { mkdir, rm, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const frontendDir = dirname(fileURLToPath(import.meta.url));
const distDir = resolve(frontendDir, "dist");
const assetsDir = resolve(distDir, "assets");

await rm(distDir, { recursive: true, force: true });
await mkdir(assetsDir, { recursive: true });

await build({
  absWorkingDir: frontendDir,
  bundle: true,
  entryPoints: {
    app: resolve(frontendDir, "src/main.tsx"),
  },
  entryNames: "[name]",
  format: "esm",
  jsx: "automatic",
  minify: false,
  outdir: assetsDir,
  platform: "browser",
  sourcemap: "inline",
  target: ["es2022"],
  loader: {
    ".css": "css",
  },
});

const html = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta
      name="viewport"
      content="width=device-width, initial-scale=1, viewport-fit=cover"
    />
    <title>Ticket Kanban</title>
    <link rel="stylesheet" href="./assets/app.css" />
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="./assets/app.js"></script>
  </body>
</html>
`;

await writeFile(resolve(distDir, "index.html"), html, "utf8");
console.log(`built ${resolve(distDir, "index.html")}`);
