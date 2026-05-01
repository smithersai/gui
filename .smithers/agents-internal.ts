// Pure helpers extracted for unit testability.
// Side-effect-free utilities used by orchestrator workflows: agent selection,
// feature-flag gating, retry/backoff calculations, and schedule parsing.

export type AgentTier = "cheapFast" | "smart" | "smartTool" | "frontendcheap" | "reviewSmart";

const TIER_ORDER: readonly AgentTier[] = [
  "cheapFast",
  "frontendcheap",
  "smartTool",
  "smart",
  "reviewSmart",
] as const;

/**
 * Pick an agent tier based on requirements. Returns the cheapest tier that
 * satisfies all of the supplied capability flags.
 */
export function selectAgentTier(opts: {
  needsTools?: boolean;
  needsReview?: boolean;
  frontendOnly?: boolean;
} = {}): AgentTier {
  if (opts.needsReview) return "reviewSmart";
  if (opts.needsTools) return "smartTool";
  if (opts.frontendOnly) return "frontendcheap";
  return "cheapFast";
}

/** Return whether `tier` is a known agent tier. */
export function isAgentTier(value: unknown): value is AgentTier {
  return typeof value === "string" && (TIER_ORDER as readonly string[]).includes(value);
}

/**
 * Feature-flag gate: returns true when the named flag is enabled in the env map.
 * Only "1", "true", "yes", "on" (case-insensitive) count as enabled. Empty,
 * unset, or anything else is disabled.
 */
export function isFeatureEnabled(env: Record<string, string | undefined>, flag: string): boolean {
  if (!flag) return false;
  const raw = env[flag];
  if (raw === undefined || raw === null) return false;
  const v = String(raw).trim().toLowerCase();
  return v === "1" || v === "true" || v === "yes" || v === "on";
}

/**
 * Retry policy: exponential backoff with jitter cap. Returns delay in ms for the
 * given attempt (0-indexed). Caps at `maxMs`. Returns 0 for invalid attempts.
 */
export function retryDelayMs(attempt: number, baseMs = 250, maxMs = 30_000): number {
  if (!Number.isFinite(attempt) || attempt < 0) return 0;
  if (!Number.isFinite(baseMs) || baseMs <= 0) return 0;
  if (!Number.isFinite(maxMs) || maxMs <= 0) return 0;
  const a = Math.floor(attempt);
  // 2^a but guard against overflow
  if (a > 30) return Math.min(maxMs, baseMs * 2 ** 30);
  return Math.min(maxMs, baseMs * 2 ** a);
}

/**
 * Parse a simple schedule literal of the form "<n><unit>" where unit is
 * s|m|h|d. Returns milliseconds, or null on parse failure.
 */
export function parseSchedule(input: string): number | null {
  if (typeof input !== "string") return null;
  const trimmed = input.trim().toLowerCase();
  if (!trimmed) return null;
  const m = /^(\d+)\s*(ms|s|m|h|d)$/.exec(trimmed);
  if (!m) return null;
  const n = Number(m[1]);
  if (!Number.isFinite(n) || n < 0) return null;
  switch (m[2]) {
    case "ms":
      return n;
    case "s":
      return n * 1_000;
    case "m":
      return n * 60_000;
    case "h":
      return n * 3_600_000;
    case "d":
      return n * 86_400_000;
    default:
      return null;
  }
}
