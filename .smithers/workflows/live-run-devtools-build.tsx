// smithers-source: seeded
// smithers-display-name: Live Run DevTools Build
/** @jsxImportSource smithers-orchestrator */
import {
  ClaudeCodeAgent,
  CodexAgent,
  Parallel,
  createSmithers,
} from "smithers-orchestrator";
import { reviewOutputSchema } from "../components/Review";
import { implementOutputSchema } from "../components/ValidationLoop";
import ImplementPrompt from "../prompts/implement.mdx";
import ReviewPrompt from "../prompts/review.mdx";

const SPEC_PATH =
  "/Users/williamcory/smithers/.smithers/specs/live-run-devtools-ui.md";
const GUI_CWD = "/Users/williamcory/gui";
const SMITHERS_CWD = "/Users/williamcory/smithers";

// Timeouts (tuned from a failed v1 run where the 30-min implement budget
// timed out on the largest backend ticket — see run-1776370137872 post-mortem).
const IMPLEMENT_TIMEOUT_MS = 7_200_000; // 2h
const IMPLEMENT_HEARTBEAT_MS = 600_000; // 10m
const REVIEW_TIMEOUT_MS = 3_600_000; // 1h
const REVIEW_HEARTBEAT_MS = 600_000; // 10m
const IMPLEMENT_RETRIES = 1; // 2 total attempts; on retry falls through agent list

type Role = "backend" | "ui";

// Agents bundled per role + repo. cwd pins the repo each agent operates in.
//
// Implementers:
//   - UI:      primary Claude (best for SwiftUI), fallback Codex on retry.
//   - Backend: Codex only (was reliable in v1 run; Claude still listed as
//              fallback in case of codex-specific failures).
//
// Reviewers: TWO Codex instances — one at default reasoning effort, one at
// xhigh. ClaudeCodeAgent was removed from reviewers after v1 review failures
// ("No valid JSON output found in agent response"); Codex enforces the output
// schema at the CLI layer via --output-schema and reliably produces JSON.
const guiAgents = {
  implementer: [
    new ClaudeCodeAgent({ model: "claude-opus-4-6", cwd: GUI_CWD }),
    new CodexAgent({
      model: "gpt-5.3-codex",
      skipGitRepoCheck: true,
      cwd: GUI_CWD,
    }),
  ],
  reviewers: [
    new CodexAgent({
      model: "gpt-5.3-codex",
      skipGitRepoCheck: true,
      cwd: GUI_CWD,
    }),
    new CodexAgent({
      model: "gpt-5.3-codex",
      skipGitRepoCheck: true,
      cwd: GUI_CWD,
      config: { model_reasoning_effort: "xhigh" },
    }),
  ],
};

const smithersAgents = {
  implementer: [
    new CodexAgent({
      model: "gpt-5.3-codex",
      skipGitRepoCheck: true,
      cwd: SMITHERS_CWD,
    }),
    new ClaudeCodeAgent({ model: "claude-opus-4-6", cwd: SMITHERS_CWD }),
  ],
  reviewers: [
    new CodexAgent({
      model: "gpt-5.3-codex",
      skipGitRepoCheck: true,
      cwd: SMITHERS_CWD,
    }),
    new CodexAgent({
      model: "gpt-5.3-codex",
      skipGitRepoCheck: true,
      cwd: SMITHERS_CWD,
      config: { model_reasoning_effort: "xhigh" },
    }),
  ],
};

type Ticket = {
  key: string;
  id: string;
  path: string;
  role: Role;
  deps?: readonly string[];
};

const tickets = {
  s10: {
    key: "s10",
    id: "smithers-0010",
    path: "/Users/williamcory/smithers/.smithers/tickets/0010-devtools-tree-streaming-rpc.md",
    role: "backend",
  },
  s11: {
    key: "s11",
    id: "smithers-0011",
    path: "/Users/williamcory/smithers/.smithers/tickets/0011-get-node-diff-rpc.md",
    role: "backend",
  },
  s12: {
    key: "s12",
    id: "smithers-0012",
    path: "/Users/williamcory/smithers/.smithers/tickets/0012-get-node-output-rpc.md",
    role: "backend",
  },
  s13: {
    key: "s13",
    id: "smithers-0013",
    path: "/Users/williamcory/smithers/.smithers/tickets/0013-time-travel-jump-to-frame.md",
    role: "backend",
    deps: ["smithers-0010"],
  },
  s14: {
    key: "s14",
    id: "smithers-0014",
    path: "/Users/williamcory/smithers/.smithers/tickets/0014-devtools-live-run-cli.md",
    role: "backend",
    deps: ["smithers-0010", "smithers-0011", "smithers-0012", "smithers-0013"],
  },
  g74: {
    key: "g74",
    id: "gui-0074",
    path: "/Users/williamcory/gui/.smithers/tickets/0074-live-run-devtools-wire-client.md",
    role: "ui",
    deps: ["smithers-0010"],
  },
  g75: {
    key: "g75",
    id: "gui-0075",
    path: "/Users/williamcory/gui/.smithers/tickets/0075-live-run-tree-pane.md",
    role: "ui",
    deps: ["gui-0074"],
  },
  g76: {
    key: "g76",
    id: "gui-0076",
    path: "/Users/williamcory/gui/.smithers/tickets/0076-live-run-inspector-shell.md",
    role: "ui",
    deps: ["gui-0074"],
  },
  g77: {
    key: "g77",
    id: "gui-0077",
    path: "/Users/williamcory/gui/.smithers/tickets/0077-live-run-output-tab.md",
    role: "ui",
    deps: ["gui-0076", "smithers-0012"],
  },
  g78: {
    key: "g78",
    id: "gui-0078",
    path: "/Users/williamcory/gui/.smithers/tickets/0078-live-run-diff-tab.md",
    role: "ui",
    deps: ["gui-0076", "smithers-0011"],
  },
  g79: {
    key: "g79",
    id: "gui-0079",
    path: "/Users/williamcory/gui/.smithers/tickets/0079-live-run-logs-tab.md",
    role: "ui",
    deps: ["gui-0076"],
  },
  g80: {
    key: "g80",
    id: "gui-0080",
    path: "/Users/williamcory/gui/.smithers/tickets/0080-live-run-header-dual-heartbeats.md",
    role: "ui",
    deps: ["gui-0074"],
  },
  g81: {
    key: "g81",
    id: "gui-0081",
    path: "/Users/williamcory/gui/.smithers/tickets/0081-live-run-time-travel-scrubber.md",
    role: "ui",
    deps: ["gui-0074", "gui-0075", "smithers-0010", "smithers-0013"],
  },
  g82: {
    key: "g82",
    id: "gui-0082",
    path: "/Users/williamcory/gui/.smithers/tickets/0082-retire-live-run-chat-view.md",
    role: "ui",
    deps: [
      "gui-0075",
      "gui-0076",
      "gui-0077",
      "gui-0078",
      "gui-0079",
      "gui-0080",
      "gui-0081",
    ],
  },
} as const satisfies Record<string, Ticket>;

function buildPrompt(t: Ticket): string {
  const roleLine =
    t.role === "ui"
      ? "Role: Swift/SwiftUI UI in /Users/williamcory/gui. Write SwiftUI views, Swift models, and tests under Tests/. Validate with xcodebuild / swift test."
      : "Role: TypeScript backend in /Users/williamcory/smithers. Write TS modules, Drizzle schema changes, gateway RPCs, and tests. Validate with bun test.";
  const depsLine = t.deps?.length
    ? `Depends on: ${t.deps.join(", ")} — those tickets have already been implemented. Read their changes from the tree and build on top of them.`
    : "No upstream ticket dependencies.";
  return [
    `Implement ticket ${t.id}.`,
    "",
    roleLine,
    depsLine,
    "",
    "Spec (single source of truth — read first):",
    `  ${SPEC_PATH}`,
    "",
    "Ticket (exact scope + acceptance criteria — implement only this):",
    `  ${t.path}`,
    "",
    "Process:",
    "  1. Read the spec so the feature vision is in your head.",
    "  2. Read the ticket. Implement exactly what its Scope section says. Satisfy every Acceptance bullet.",
    "  3. Reuse existing patterns/components/helpers in the repo. Do not expand scope, rename unrelated things, or add cleanups.",
    "  4. Write tests as the ticket specifies. Run them. Do not declare done until they pass.",
    "  5. For UI tickets: per the user's standing instruction, run the app end-to-end and verify the behavior in-browser / in-app before reporting success. If you cannot run it, say so explicitly.",
    "",
    "Return the implement output schema truthfully: list the files you changed and whether tests pass.",
    "CRITICAL: Your final message must be a single valid JSON object matching the output schema — no markdown fences, no prose, no preamble.",
  ].join("\n");
}

function buildReviewPrompt(t: Ticket): string {
  return [
    `Review an implementation of ticket ${t.id}.`,
    "",
    "Spec:   " + SPEC_PATH,
    "Ticket: " + t.path,
    "",
    "This is a read-only code review. Do NOT run builds, tests, xcodebuild, bun test, swift test, or the app — the test suite is executed elsewhere and the implementer already reported pass/fail in their output. Your job is to READ code and judge it against the ticket.",
    "",
    "Read:",
    "  - the spec (feature vision),",
    "  - the ticket (exact scope + acceptance criteria),",
    "  - the most recent changes on disk (git diff HEAD~1 or the last commit touching this ticket's files).",
    "",
    "Judge strictly against the ticket's Acceptance section:",
    "  - Does the implementation cover every acceptance bullet? Missing any → reject.",
    "  - Are the tests described in the ticket actually written? Read the test code and judge whether it plausibly covers the acceptance cases. Do NOT execute tests.",
    "  - Does it respect ticket boundaries? Obvious scope creep → note as an issue (don't reject solely on this, but flag).",
    "  - For UI tickets: does the view/model code match the spec's §2 description (layout, state machine, props, accessibility hooks)? Do NOT run the app — assess by reading the Swift source.",
    "",
    "Do not bikeshed: approve if the ticket's scope is met, even if you would have chosen a different abstraction. Keep the review fast — minutes, not tens of minutes.",
    "CRITICAL: Your final message must be a single valid JSON object matching the review schema (reviewer/approved/feedback/issues) — no markdown fences, no prose, no preamble.",
  ].join("\n");
}

const { Workflow, Sequence, Task, smithers } = createSmithers({
  implement: implementOutputSchema,
  review: reviewOutputSchema,
});

function ticketBuild(t: Ticket) {
  const bundle = t.role === "ui" ? guiAgents : smithersAgents;
  const implPrompt = buildPrompt(t);
  const revPrompt = buildReviewPrompt(t);

  return (
    <Sequence>
      <Task
        id={`${t.key}:implement`}
        output={implementOutputSchema}
        agent={bundle.implementer}
        retries={IMPLEMENT_RETRIES}
        timeoutMs={IMPLEMENT_TIMEOUT_MS}
        heartbeatTimeoutMs={IMPLEMENT_HEARTBEAT_MS}
      >
        <ImplementPrompt prompt={implPrompt} />
      </Task>
      <Parallel>
        {bundle.reviewers.map((agent, i) => (
          <Task
            key={`${t.key}:review:${i}`}
            id={`${t.key}:review:${i}`}
            output={reviewOutputSchema}
            agent={agent}
            continueOnFail
            timeoutMs={REVIEW_TIMEOUT_MS}
            heartbeatTimeoutMs={REVIEW_HEARTBEAT_MS}
          >
            <ReviewPrompt
              reviewer={`${t.key}:reviewer-${i + 1}`}
              prompt={revPrompt}
            />
          </Task>
        ))}
      </Parallel>
    </Sequence>
  );
}

export default smithers(() => (
  <Workflow name="live-run-devtools-build">
    <Sequence>
      {/* Phase 1 — independent backend RPCs (no deps). */}
      <Parallel>
        {ticketBuild(tickets.s10)}
        {ticketBuild(tickets.s11)}
        {ticketBuild(tickets.s12)}
      </Parallel>

      {/* Phase 2 — work blocked on S-0010. */}
      <Parallel>
        {ticketBuild(tickets.s13)}
        {ticketBuild(tickets.g74)}
      </Parallel>

      {/* Phase 3 — UI skeleton; all need G-0074. */}
      <Parallel>
        {ticketBuild(tickets.g75)}
        {ticketBuild(tickets.g76)}
        {ticketBuild(tickets.g80)}
      </Parallel>

      {/* Phase 4 — tabs and time-travel; all have their backend/shell deps met. */}
      <Parallel>
        {ticketBuild(tickets.g77)}
        {ticketBuild(tickets.g78)}
        {ticketBuild(tickets.g79)}
        {ticketBuild(tickets.g81)}
      </Parallel>

      {/* Phase 5 — CLI + final gui integration (independent of each other). */}
      <Parallel>
        {ticketBuild(tickets.s14)}
        {ticketBuild(tickets.g82)}
      </Parallel>
    </Sequence>
  </Workflow>
));
