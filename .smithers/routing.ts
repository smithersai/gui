// Pure routing/dispatch helpers used by orchestrator workflows.

/**
 * Normalize a workflow/dispatch route. Lowercases, collapses runs of `/`,
 * strips leading/trailing slashes, removes a trailing `/index`, and
 * percent-decodes safely (idempotent — never double-encodes).
 *
 * Returns null on invalid input.
 */
export function normalizeRoute(input: string): string | null {
  if (typeof input !== "string") return null;
  const trimmed = input.trim();
  if (!trimmed) return null;

  let s = trimmed;
  // Decode safely. If decoding fails (invalid escape), keep original.
  try {
    const decoded = decodeURIComponent(s);
    // If decoding yields something with control chars, reject.
    if (/[\x00-\x1f\x7f]/.test(decoded)) return null;
    s = decoded;
  } catch {
    return null;
  }

  s = s.toLowerCase();
  // Collapse repeated slashes, including from accidental double-encoding.
  s = s.replace(/\/+/g, "/");
  // Strip leading and trailing slashes.
  s = s.replace(/^\/+|\/+$/g, "");
  // Strip a trailing "index" segment (with or without preceding path).
  s = s.replace(/(^|\/)index$/, "");
  if (!s) return "/";
  return "/" + s;
}

/**
 * Pick a dispatcher target from a list of routes that prefix-match the
 * supplied path. Longest match wins. Returns null if nothing matches.
 */
export function pickRoute(path: string, routes: readonly string[]): string | null {
  const normalized = normalizeRoute(path);
  if (normalized == null) return null;

  let best: string | null = null;
  for (const r of routes) {
    const nr = normalizeRoute(r);
    if (nr == null) continue;
    if (normalized === nr || normalized.startsWith(nr === "/" ? "/" : nr + "/")) {
      if (!best || nr.length > best.length) best = nr;
    }
  }
  return best;
}

/**
 * Join route segments. Empty / null / undefined segments are skipped. The
 * result is run through `normalizeRoute`.
 */
export function joinRoute(...segments: Array<string | null | undefined>): string | null {
  const parts = segments
    .filter((s): s is string => typeof s === "string" && s.length > 0)
    .map((s) => s.replace(/^\/+|\/+$/g, ""))
    .filter((s) => s.length > 0);
  if (!parts.length) return "/";
  return normalizeRoute(parts.join("/"));
}
