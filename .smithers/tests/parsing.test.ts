import { describe, expect, test } from "bun:test";
import { normalizeRef, parseTicketId, slugify, ticketFilename } from "../parsing";

describe("parseTicketId", () => {
  test("parses .md ticket", () => {
    const t = parseTicketId("0001-foo-bar.md");
    expect(t).toEqual({ number: "0001", num: 1, slug: "foo-bar" });
  });

  test("parses without extension", () => {
    expect(parseTicketId("0042-baz")).toEqual({ number: "0042", num: 42, slug: "baz" });
  });

  test("parses absolute paths", () => {
    expect(parseTicketId("/Users/foo/.smithers/tickets/0123-thing.md"))
      .toEqual({ number: "0123", num: 123, slug: "thing" });
  });

  test("normalizes short numbers", () => {
    expect(parseTicketId("7-x")).toEqual({ number: "0007", num: 7, slug: "x" });
  });

  test("number-only is valid (no slug)", () => {
    expect(parseTicketId("9.md")).toEqual({ number: "0009", num: 9, slug: "" });
  });

  test("rejects malformed inputs", () => {
    expect(parseTicketId("")).toBeNull();
    expect(parseTicketId("   ")).toBeNull();
    expect(parseTicketId("foo-bar.md")).toBeNull();
    expect(parseTicketId("-1-foo")).toBeNull();
    expect(parseTicketId("abc")).toBeNull();
  });

  test("rejects non-string", () => {
    // @ts-expect-error testing non-string
    expect(parseTicketId(null)).toBeNull();
    // @ts-expect-error testing non-string
    expect(parseTicketId(123)).toBeNull();
  });

  test("very large ticket number", () => {
    const t = parseTicketId("99999-huge");
    expect(t?.num).toBe(99999);
    expect(t?.number).toBe("99999"); // padding only matters under 4 digits
  });
});

describe("slugify", () => {
  test("basic title", () => {
    expect(slugify("Hello World")).toBe("hello-world");
  });

  test("collapses non-alnum", () => {
    expect(slugify("foo!!!  bar??")).toBe("foo-bar");
  });

  test("trims edges", () => {
    expect(slugify("  --foo--  ")).toBe("foo");
  });

  test("handles empty", () => {
    expect(slugify("")).toBe("");
    expect(slugify("    ")).toBe("");
    expect(slugify("---")).toBe("");
  });

  test("strips diacritics", () => {
    expect(slugify("Café Déjà-Vu")).toBe("cafe-deja-vu");
  });

  test("non-latin unicode is dropped (ASCII-only output)", () => {
    expect(slugify("こんにちは world")).toBe("world");
  });

  test("emoji is dropped", () => {
    expect(slugify("rocket 🚀 launch")).toBe("rocket-launch");
  });

  test("non-string input", () => {
    // @ts-expect-error testing non-string
    expect(slugify(null)).toBe("");
    // @ts-expect-error testing non-string
    expect(slugify(undefined)).toBe("");
  });
});

describe("normalizeRef", () => {
  test("happy path", () => {
    expect(normalizeRef("main")).toBe("main");
    expect(normalizeRef("feature/foo")).toBe("feature/foo");
  });

  test("strips refs/heads/ and refs/tags/", () => {
    expect(normalizeRef("refs/heads/main")).toBe("main");
    expect(normalizeRef("refs/tags/v1.0.0")).toBe("v1.0.0");
  });

  test("strips trailing slashes", () => {
    expect(normalizeRef("foo/")).toBe("foo");
    expect(normalizeRef("foo///")).toBe("foo");
  });

  test("rejects empty / whitespace", () => {
    expect(normalizeRef("")).toBeNull();
    expect(normalizeRef("   ")).toBeNull();
    expect(normalizeRef("/")).toBeNull();
  });

  test("rejects refs with control chars / spaces / disallowed glyphs", () => {
    expect(normalizeRef("foo bar")).toBeNull();
    expect(normalizeRef("foo\tbar")).toBeNull();
    expect(normalizeRef("foo~bar")).toBeNull();
    expect(normalizeRef("foo^bar")).toBeNull();
    expect(normalizeRef("foo:bar")).toBeNull();
    expect(normalizeRef("foo\x00bar")).toBeNull();
  });

  test("rejects path traversal", () => {
    expect(normalizeRef("foo/../bar")).toBeNull();
    expect(normalizeRef("..")).toBeNull();
  });

  test("non-string input", () => {
    // @ts-expect-error testing non-string
    expect(normalizeRef(null)).toBeNull();
  });
});

describe("ticketFilename", () => {
  test("basic", () => {
    expect(ticketFilename(1, "Foo Bar")).toBe("0001-foo-bar.md");
  });

  test("custom extension", () => {
    expect(ticketFilename(42, "thing", "mdx")).toBe("0042-thing.mdx");
    expect(ticketFilename(42, "thing", ".mdx")).toBe("0042-thing.mdx");
  });

  test("number-only when title slugifies to empty", () => {
    expect(ticketFilename(5, "🚀🚀🚀")).toBe("0005.md");
  });

  test("rejects negative / non-finite", () => {
    expect(() => ticketFilename(-1, "x")).toThrow();
    expect(() => ticketFilename(NaN, "x")).toThrow();
    expect(() => ticketFilename(Infinity, "x")).toThrow();
  });

  test("floors fractional numbers", () => {
    expect(ticketFilename(7.9, "thing")).toBe("0007-thing.md");
  });

  test("large number does not pad-truncate", () => {
    expect(ticketFilename(123456, "x")).toBe("123456-x.md");
  });
});
