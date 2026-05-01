import { existsSync, readdirSync } from "node:fs";

type RunResult = {
  code: number;
  stdout: string;
  stderr: string;
};

const repoRoot = `${import.meta.dir}/../..`;
const ghosttyDir = `${repoRoot}/ghostty`;
const patchesDir = `${repoRoot}/linux/patches`;

async function run(args: string[], cwd: string): Promise<RunResult> {
  const proc = Bun.spawn(args, {
    cwd,
    stdout: "pipe",
    stderr: "pipe",
  });
  const stdout = await new Response(proc.stdout).text();
  const stderr = await new Response(proc.stderr).text();
  const code = await proc.exited;
  return { code, stdout, stderr };
}

function oneLine(text: string): string {
  return text.trim().split("\n").map((line) => line.trim()).filter(Boolean).join("; ");
}

if (!existsSync(ghosttyDir)) {
  console.error(`ghostty directory not found: ${ghosttyDir}`);
  process.exit(1);
}

if (!existsSync(patchesDir)) {
  console.log("no ghostty patches directory found; skipping");
  process.exit(0);
}

const patches = readdirSync(patchesDir)
  .filter((name) => name.endsWith(".patch"))
  .sort();

if (patches.length === 0) {
  console.log("no ghostty patches found; skipping");
  process.exit(0);
}

let failed = false;

for (const patch of patches) {
  const patchPath = `${patchesDir}/${patch}`;
  const check = await run(["git", "apply", "--check", patchPath], ghosttyDir);
  if (check.code === 0) {
    const apply = await run(["git", "apply", patchPath], ghosttyDir);
    if (apply.code === 0) {
      console.log(`${patch}: applied`);
      continue;
    }
    console.error(`${patch}: failed: ${oneLine(apply.stderr || apply.stdout)}`);
    failed = true;
    continue;
  }

  const reverse = await run(["git", "apply", "--reverse", "--check", patchPath], ghosttyDir);
  if (reverse.code === 0) {
    console.log(`${patch}: already applied`);
    continue;
  }

  console.error(`${patch}: failed: ${oneLine(check.stderr || check.stdout)}`);
  failed = true;
}

process.exit(failed ? 1 : 0);
