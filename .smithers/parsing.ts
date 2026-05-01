// Pure string-parsing helpers for tickets, refs, and slugs.

export interface TicketId {
  /** Zero-padded 4-digit numeric prefix. */
  number: string;
  /** Numeric prefix as a JS number. */
  num: number;
  /** Slug portion (after the number, before any extension). */
  slug: string;
}

/**
 * Parse a ticket filename or id. Accepts forms like:
 *   "0001-foo-bar.md"
 *   "0001-foo-bar"
 *   "1-foo"           (will be normalized to 0001)
 *   "/path/to/0001-foo-bar.md"
 *
 * Returns null if the input is malformed (no leading number, empty, etc).
 */
export function parseTicketId(input: string): TicketId | null {
  if (typeof input !== "string") return null;
  const raw = input.trim();
  if (!raw) return null;

  // Strip directory components.
  const base = raw.replace(/^.*\//, "");
  // Strip extension (.md, .mdx, .txt, etc).
  const noExt = base.replace(/\.[a-z0-9]+$/i, "");

  const m = /^(\d+)(?:-(.*))?$/.exec(noExt);
  if (!m) return null;
  const num = Number(m[1]);
  if (!Number.isFinite(num) || num < 0) return null;
  const slug = (m[2] ?? "").trim();
  return {
    number: String(num).padStart(4, "0"),
    num,
    slug,
  };
}

/**
 * Slugify a free-form title. Lowercases, replaces non-alphanumerics with
 * hyphens, collapses repeats, trims leading/trailing hyphens. Unicode letters
 * are stripped (ASCII-only slugs).
 */
export function slugify(input: string): string {
  if (typeof input !== "string") return "";
  return input
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "") // strip combining marks
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

/**
 * Normalize a git-like ref. Strips whitespace, leading "refs/heads/", and any
 * trailing slashes. Returns null for empty / invalid refs.
 */
export function normalizeRef(input: string): string | null {
  if (typeof input !== "string") return null;
  let s = input.trim();
  if (!s) return null;
  if (s.startsWith("refs/heads/")) s = s.slice("refs/heads/".length);
  else if (s.startsWith("refs/tags/")) s = s.slice("refs/tags/".length);
  s = s.replace(/\/+$/, "");
  if (!s) return null;
  // Disallow control chars, spaces, and characters git itself rejects.
  if (/[\s~^:?*\[\\\x00-\x1f\x7f]/.test(s)) return null;
  if (s.includes("..")) return null;
  return s;
}

/**
 * Build the canonical ticket filename from a number + title. Pads the number
 * to 4 digits and slugifies the title.
 */
export function ticketFilename(num: number, title: string, ext = "md"): string {
  if (!Number.isFinite(num) || num < 0) throw new RangeError("num must be non-negative finite");
  const n = String(Math.floor(num)).padStart(4, "0");
  const slug = slugify(title);
  const safeExt = ext.replace(/^\.+/, "");
  return slug ? `${n}-${slug}.${safeExt}` : `${n}.${safeExt}`;
}
