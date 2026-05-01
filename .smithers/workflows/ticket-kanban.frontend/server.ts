import { readdir, readFile } from "node:fs/promises";
import { basename, dirname, extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

type FrontendManifest = {
  version: number;
  id: string;
  name: string;
  framework?: string;
  entry: string;
  apiBasePath?: string;
  defaultPath?: string;
};

type RunSummary = {
  id?: string;
  runId?: string;
  workflow?: string;
  workflowName?: string;
  status?: string;
  started?: string;
  startedAtMs?: number;
  finishedAtMs?: number;
  summary?: Record<string, number>;
};

type InspectStep = {
  id?: string;
  state?: string;
  attempt?: number;
  label?: string | null;
};

type InspectResponse = {
  run?: {
    id?: string;
    runId?: string;
    workflow?: string;
    workflowName?: string;
    status?: string;
    started?: string;
    elapsed?: string;
  };
  steps?: InspectStep[];
  loops?: Array<{ loopId?: string; iteration?: number }>;
  config?: Record<string, unknown>;
};

type NodeMetaResponse = {
  node?: {
    outputTable?: string | null;
    state?: string | null;
  };
  attempts?: Array<{
    meta?: {
      staticPayload?: Record<string, unknown> | null;
      outputTable?: string | null;
    } | null;
  }>;
};

type TicketRecord = {
  id: string;
  slug: string;
  filePath: string;
  title: string;
  summary: string;
  content: string;
};

type TicketBoardStatus = "todo" | "in-progress" | "in-review" | "needs-attention" | "done";

type TicketBoardCard = {
  id: string;
  slug: string;
  title: string;
  summary: string;
  filePath: string;
  status: TicketBoardStatus;
  branch: string;
  stepStates: {
    implement: string;
    validate: string;
    reviews: string[];
    result: string;
  };
  detail: string;
};

type BoardPayload = {
  workflow: {
    id: string;
    name: string;
    framework: string;
  };
  selectedRun: {
    runId: string;
    status: string;
    started: string | null;
    elapsed: string | null;
  } | null;
  recentRuns: Array<{
    runId: string;
    status: string;
    started: string | null;
    selected: boolean;
  }>;
  columns: Array<{
    id: TicketBoardStatus;
    label: string;
    count: number;
  }>;
  tickets: TicketBoardCard[];
  generatedAt: string;
};

const frontendDir = dirname(fileURLToPath(import.meta.url));
const workspaceRoot = resolve(frontendDir, "..", "..", "..");
const ticketsDir = resolve(workspaceRoot, ".smithers", "tickets");
const manifestPath = resolve(frontendDir, "manifest.json");

const args = parseArgs(Bun.argv.slice(2));
const requestedPort = parseInt(args.port ?? "0", 10);

const manifest = await readJSON<FrontendManifest>(manifestPath);
const entryPath = resolve(frontendDir, manifest.entry);
const distDir = dirname(entryPath);

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: Number.isFinite(requestedPort) ? requestedPort : 0,
  fetch: handleRequest,
});

console.log(JSON.stringify({
  type: "ready",
  port: server.port,
  workflowId: manifest.id,
}));

async function handleRequest(request: Request): Promise<Response> {
  const url = new URL(request.url);

  if (url.pathname === "/api/health") {
    return json({ ok: true, workflowId: manifest.id });
  }

  if (url.pathname === "/api/workflow") {
    return json({
      manifest,
      frontendDir,
      workspaceRoot,
    });
  }

  if (url.pathname === "/api/runs") {
    const runs = await listWorkflowRuns(manifest.id);
    return json({
      workflowId: manifest.id,
      runs,
    });
  }

  if (url.pathname === "/api/board") {
    const payload = await buildBoardPayload(url.searchParams.get("runId"));
    return json(payload);
  }

  if (url.pathname === "/api/run" && request.method === "POST") {
    const body = await request.json().catch(() => ({}));
    const maxConcurrency = typeof body?.maxConcurrency === "number"
      ? Math.max(1, Math.floor(body.maxConcurrency))
      : null;
    const result = await runJSON<{
      runId: string;
      logFile?: string;
      pid?: number;
    }>(buildRunCommand(maxConcurrency));
    return json(result, { status: 202 });
  }

  const cancelMatch = url.pathname.match(/^\/api\/runs\/([^/]+)\/cancel$/);
  if (cancelMatch && request.method === "POST") {
    const runId = decodeURIComponent(cancelMatch[1]);
    const result = await runJSON<Record<string, unknown>>([
      "smithers",
      "cancel",
      runId,
      "--format",
      "json",
    ]);
    return json(result);
  }

  if (url.pathname === "/" || url.pathname === manifest.defaultPath || !url.pathname.startsWith("/api/")) {
    return serveStatic(url.pathname);
  }

  return json({ error: "Not found" }, { status: 404 });
}

function buildRunCommand(maxConcurrency: number | null): string[] {
  const args = [
    "smithers",
    "workflow",
    "run",
    manifest.id,
    "--detach",
    "--format",
    "json",
  ];

  if (maxConcurrency !== null) {
    args.push("--input", JSON.stringify({ maxConcurrency }));
  }

  return args;
}

async function buildBoardPayload(requestedRunId: string | null): Promise<BoardPayload> {
  const tickets = await loadTickets();
  const recentRuns = await listWorkflowRuns(manifest.id);
  const selectedRunId = requestedRunId
    ?? recentRuns[0]?.runId
    ?? null;

  if (!selectedRunId) {
    const cards = tickets.map((ticket) => emptyTicketCard(ticket));
    return {
      workflow: {
        id: manifest.id,
        name: manifest.name,
        framework: manifest.framework ?? "react",
      },
      selectedRun: null,
      recentRuns: [],
      columns: summarizeColumns(cards),
      tickets: cards,
      generatedAt: new Date().toISOString(),
    };
  }

  const inspect = await runJSON<InspectResponse>([
    "smithers",
    "inspect",
    selectedRunId,
    "--format",
    "json",
  ]);

  const steps = inspect.steps ?? [];
  const stepMap = new Map<string, InspectStep>();
  for (const step of steps) {
    if (step.id) {
      stepMap.set(step.id, step);
    }
  }

  const cards = await Promise.all(
    tickets.map(async (ticket) => buildTicketCard(ticket, selectedRunId, stepMap))
  );

  return {
    workflow: {
      id: manifest.id,
      name: manifest.name,
      framework: manifest.framework ?? "react",
    },
    selectedRun: {
      runId: inspect.run?.id ?? inspect.run?.runId ?? selectedRunId,
      status: inspect.run?.status ?? "unknown",
      started: inspect.run?.started ?? null,
      elapsed: inspect.run?.elapsed ?? null,
    },
    recentRuns: recentRuns.map((run) => ({
      runId: run.runId,
      status: run.status,
      started: run.started,
      selected: run.runId === selectedRunId,
    })),
    columns: summarizeColumns(cards),
    tickets: cards,
    generatedAt: new Date().toISOString(),
  };
}

async function buildTicketCard(
  ticket: TicketRecord,
  runId: string,
  stepMap: Map<string, InspectStep>
): Promise<TicketBoardCard> {
  const implementState = normalizedStepState(stepMap.get(`${ticket.slug}:implement`)?.state);
  const validateState = normalizedStepState(stepMap.get(`${ticket.slug}:validate`)?.state);
  const reviewStates = [...stepMap.entries()]
    .filter(([stepId]) => stepId.startsWith(`${ticket.slug}:review:`))
    .map(([, step]) => normalizedStepState(step.state))
    .sort();
  const resultState = normalizedStepState(stepMap.get(`result-${ticket.slug}`)?.state);

  let branch = `ticket/${ticket.slug}`;
  let detail = detailText({
    implementState,
    validateState,
    reviewStates,
    resultState,
  });

  if (resultState == "finished") {
    const resultNode = await loadResultNode(runId, ticket.slug);
    const payload = resultNode?.attempts?.[0]?.meta?.staticPayload ?? null;
    if (payload && typeof payload.branch === "string" && payload.branch.trim().length > 0) {
      branch = payload.branch;
    }
    if (payload && typeof payload.summary === "string" && payload.summary.trim().length > 0) {
      detail = payload.summary;
    }
  }

  return {
    id: ticket.id,
    slug: ticket.slug,
    title: ticket.title,
    summary: ticket.summary,
    filePath: ticket.filePath,
    status: deriveTicketStatus({
      implementState,
      validateState,
      reviewStates,
      resultState,
    }),
    branch,
    stepStates: {
      implement: implementState,
      validate: validateState,
      reviews: reviewStates,
      result: resultState,
    },
    detail,
  };
}

async function loadResultNode(runId: string, slug: string): Promise<NodeMetaResponse | null> {
  try {
    return await runJSON<NodeMetaResponse>([
      "smithers",
      "node",
      `result-${slug}`,
      "--run-id",
      runId,
      "--format",
      "json",
    ]);
  } catch {
    return null;
  }
}

function summarizeColumns(cards: TicketBoardCard[]): BoardPayload["columns"] {
  const order: Array<{ id: TicketBoardStatus; label: string }> = [
    { id: "todo", label: "Todo" },
    { id: "in-progress", label: "In Progress" },
    { id: "in-review", label: "In Review" },
    { id: "needs-attention", label: "Needs Attention" },
    { id: "done", label: "Done" },
  ];

  return order.map((entry) => ({
    id: entry.id,
    label: entry.label,
    count: cards.filter((card) => card.status === entry.id).length,
  }));
}

function emptyTicketCard(ticket: TicketRecord): TicketBoardCard {
  return {
    id: ticket.id,
    slug: ticket.slug,
    title: ticket.title,
    summary: ticket.summary,
    filePath: ticket.filePath,
    status: "todo",
    branch: `ticket/${ticket.slug}`,
    stepStates: {
      implement: "pending",
      validate: "pending",
      reviews: [],
      result: "pending",
    },
    detail: "No run selected.",
  };
}

function deriveTicketStatus(states: {
  implementState: string;
  validateState: string;
  reviewStates: string[];
  resultState: string;
}): TicketBoardStatus {
  if (states.resultState === "finished") {
    return "done";
  }

  if (
    states.implementState === "failed" ||
    states.validateState === "failed" ||
    states.reviewStates.includes("failed")
  ) {
    return "needs-attention";
  }

  if (
    states.implementState === "running" ||
    states.validateState === "running" ||
    states.reviewStates.includes("running")
  ) {
    return "in-progress";
  }

  if (
    states.implementState === "finished" &&
    (states.validateState !== "pending" || states.reviewStates.length > 0)
  ) {
    return "in-review";
  }

  if (states.implementState === "finished") {
    return "in-progress";
  }

  return "todo";
}

function detailText(states: {
  implementState: string;
  validateState: string;
  reviewStates: string[];
  resultState: string;
}): string {
  const reviewSummary = states.reviewStates.length > 0
    ? states.reviewStates.join(", ")
    : "not started";
  return `implement ${states.implementState}, validate ${states.validateState}, review ${reviewSummary}, result ${states.resultState}`;
}

async function loadTickets(): Promise<TicketRecord[]> {
  let entries: Array<string> = [];
  try {
    entries = (await readdir(ticketsDir))
      .filter((name) => name.endsWith(".md"))
      .sort((left, right) => left.localeCompare(right));
  } catch {
    return [];
  }

  const tickets = await Promise.all(entries.map(async (name) => {
    const filePath = join(".smithers", "tickets", name);
    const absolutePath = resolve(ticketsDir, name);
    const content = await readFile(absolutePath, "utf8");
    const parsed = parseTicketContent(content, basename(name, ".md"));
    return {
      id: name,
      slug: basename(name, ".md"),
      filePath,
      title: parsed.title,
      summary: parsed.summary,
      content,
    } satisfies TicketRecord;
  }));

  return tickets;
}

function parseTicketContent(content: string, fallbackSlug: string): { title: string; summary: string } {
  const lines = content.split(/\r?\n/);
  const heading = lines.find((line) => line.trim().startsWith("# "));
  const title = heading
    ? heading.replace(/^#\s+/, "").trim()
    : fallbackSlug.replace(/-/g, " ");

  const summaryLine = lines.find((line) => {
    const trimmed = line.trim();
    return trimmed.length > 0 && !trimmed.startsWith("#");
  });

  return {
    title,
    summary: summaryLine?.trim() ?? "No summary available.",
  };
}

async function listWorkflowRuns(workflowId: string): Promise<Array<{
  runId: string;
  status: string;
  started: string | null;
}>> {
  const result = await runJSON<{ runs?: RunSummary[] }>([
    "smithers",
    "ps",
    "--all",
    "--limit",
    "20",
    "--format",
    "json",
  ]);

  return (result.runs ?? [])
    .filter((run) => {
      const name = run.workflow ?? run.workflowName ?? "";
      return name === workflowId;
    })
    .map((run) => ({
      runId: run.id ?? run.runId ?? "",
      status: run.status ?? "unknown",
      started: run.started ?? null,
    }))
    .filter((run) => run.runId.length > 0);
}

async function runJSON<T>(cmd: string[]): Promise<T> {
  const proc = Bun.spawnSync({
    cmd,
    cwd: workspaceRoot,
    stderr: "pipe",
    stdout: "pipe",
    stdin: "ignore",
  });

  const stdout = proc.stdout.toString().trim();
  const stderr = proc.stderr.toString().trim();

  if (proc.exitCode !== 0) {
    throw new Error(stderr || stdout || `command failed: ${cmd.join(" ")}`);
  }

  if (!stdout) {
    return {} as T;
  }

  return JSON.parse(stdout) as T;
}

async function readJSON<T>(path: string): Promise<T> {
  const content = await readFile(path, "utf8");
  return JSON.parse(content) as T;
}

function normalizedStepState(value: string | undefined | null): string {
  const normalized = (value ?? "pending").trim().toLowerCase();
  switch (normalized) {
    case "complete":
    case "completed":
    case "done":
    case "success":
      return "finished";
    case "error":
      return "failed";
    default:
      return normalized;
  }
}

async function serveStatic(pathname: string): Promise<Response> {
  const normalized = pathname === "/" ? "/index.html" : pathname;
  const candidate = resolve(distDir, `.${normalized}`);
  const safePath = candidate.startsWith(distDir) ? candidate : entryPath;
  const filePath = extname(safePath).length > 0 ? safePath : entryPath;
  const file = Bun.file(filePath);

  if (!(await file.exists())) {
    const fallback = Bun.file(entryPath);
    return new Response(fallback, {
      headers: {
        "Content-Type": "text/html; charset=utf-8",
      },
    });
  }

  return new Response(file, {
    headers: {
      "Content-Type": contentTypeFor(filePath),
    },
  });
}

function contentTypeFor(path: string): string {
  switch (extname(path)) {
    case ".html":
      return "text/html; charset=utf-8";
    case ".css":
      return "text/css; charset=utf-8";
    case ".js":
      return "text/javascript; charset=utf-8";
    case ".json":
      return "application/json; charset=utf-8";
    case ".svg":
      return "image/svg+xml";
    default:
      return "application/octet-stream";
  }
}

function json(value: unknown, init?: ResponseInit): Response {
  return new Response(JSON.stringify(value), {
    ...init,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
      ...(init?.headers ?? {}),
    },
  });
}

function parseArgs(argv: string[]): Record<string, string> {
  const args: Record<string, string> = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) {
      continue;
    }
    const key = token.slice(2);
    const next = argv[index + 1];
    if (!next || next.startsWith("--")) {
      args[key] = "true";
      continue;
    }
    args[key] = next;
    index += 1;
  }
  return args;
}
