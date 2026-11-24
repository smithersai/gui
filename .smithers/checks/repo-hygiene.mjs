// Repository invariants for //.smithers:hygiene. Run from the repository root:
//   node --test .smithers/checks/repo-hygiene.mjs
// The file name has no .test. infix so `bun test` in .smithers never collects it.
import { execFileSync } from "node:child_process"
import { readdirSync, readFileSync } from "node:fs"
import assert from "node:assert/strict"
import { test } from "node:test"

const read = (path) => readFileSync(path, "utf8")
const pinned = read(".zigversion").trim()

test(".zigversion names one Zig release", () => {
  assert.match(pinned, /^\d+\.\d+\.\d+$/)
})

test("libsmithers/build.zig requires the pinned Zig", () => {
  const match = read("libsmithers/build.zig").match(
    /required_zig = std\.SemanticVersion\{ \.major = (\d+), \.minor = (\d+), \.patch = (\d+) \}/
  )
  assert.ok(match, "required_zig declaration not found")
  assert.equal(match.slice(1, 4).join("."), pinned)
})

test("linux/build.zig.zon requires the pinned Zig", () => {
  const match = read("linux/build.zig.zon").match(/\.minimum_zig_version = "([^"]+)"/)
  assert.ok(match, "minimum_zig_version not found")
  assert.equal(match[1], pinned)
})

// The lines of the workflow step that declares `id: <id>`: from that step's
// `- ` line to the next line at the same or a shallower indent.
const stepWithId = (lines, id) => {
  const idLine = lines.findIndex((line) => new RegExp(`^\\s+id:\\s*${id}\\s*$`).test(line))
  if (idLine === -1) return undefined
  let first = idLine
  while (first > 0 && !/^\s*- /.test(lines[first])) first -= 1
  const indent = lines[first].search(/\S/)
  let last = idLine + 1
  while (last < lines.length && (lines[last].trim() === "" || lines[last].search(/\S/) > indent)) last += 1
  return lines.slice(first, last).join("\n")
}

// A setup-zig version is pinned when it is the literal .zigversion value, or
// `steps.<id>.outputs.<name>` where step <id> assigns a variable from
// `$(cat .zigversion)` and writes it to <name> in $GITHUB_OUTPUT.
const versionIssue = (lines, value) => {
  if (!value.startsWith("${{")) return value === pinned ? undefined : `installs ${value}, not ${pinned}`
  const output = value.match(/^\$\{\{\s*steps\.([\w-]+)\.outputs\.([\w-]+)\s*\}\}$/)
  if (!output) return `${value} is not a step output that reads .zigversion`
  const [, id, name] = output
  const step = stepWithId(lines, id)
  if (step === undefined) return `no step has id ${id}`
  const variable = step.match(/(\w+)="\$\(cat \.zigversion\)"/)
  if (!variable) return `step ${id} does not read .zigversion`
  const written = new RegExp(`${name}=\\$\\{?${variable[1]}\\}?["\\s]`).test(step)
  return written ? undefined : `step ${id} does not write ${variable[1]} to ${name}`
}

test("every GitHub Actions setup-zig step installs the pinned Zig", () => {
  const dir = ".github/workflows"
  let steps = 0
  for (const name of readdirSync(dir).filter((file) => /\.ya?ml$/.test(file))) {
    const lines = read(`${dir}/${name}`).split("\n")
    lines.forEach((line, index) => {
      if (!/uses:\s*mlugg\/setup-zig@/.test(line)) return
      const version = lines.slice(index + 1, index + 4).join("\n").match(/version:\s*(\$\{\{[^}]*\}\}|"?[^"\s]+"?)/)
      assert.ok(version, `${name}:${index + 1} setup-zig has no version`)
      const issue = versionIssue(lines, version[1].replaceAll('"', ""))
      assert.equal(issue, undefined, `${name}:${index + 1} ${issue}`)
      steps += 1
    })
  }
  assert.ok(steps > 0, "no setup-zig steps found")
})

const shellScripts = [
  "ios/scripts/build-and-upload-testflight.sh",
  "ios/scripts/build-for-device.sh",
  "ios/scripts/happy-path-smoke.sh",
  "ios/scripts/run-e2e.sh",
  "ios/scripts/seed-e2e-data.sh",
  "ios/scripts/start-preview-tunnel.sh",
  "macos/scripts/run-e2e.sh",
  "libsmithers/scripts/build-ios-xcframework.sh",
  "libsmithers/fuzz/run.sh"
]

test("shell scripts parse", () => {
  for (const script of shellScripts) {
    const shell = read(script).startsWith("#!/usr/bin/env sh") ? "sh" : "bash"
    execFileSync(shell, ["-n", script], { stdio: "pipe" })
  }
})

test("factory projections are JSON objects", () => {
  for (const path of [".smithers/factory.json", ".smithers/home.json"]) {
    const value = JSON.parse(read(path))
    assert.ok(typeof value === "object" && value !== null && !Array.isArray(value), `${path} is not a JSON object`)
  }
})
