import { describe, expect, test } from "bun:test";
import { joinRoute, normalizeRoute, pickRoute } from "../routing";

describe("normalizeRoute", () => {
  test("happy paths", () => {
    expect(normalizeRoute("/foo/bar")).toBe("/foo/bar");
    expect(normalizeRoute("foo/bar")).toBe("/foo/bar");
    expect(normalizeRoute("/foo/bar/")).toBe("/foo/bar");
  });

  test("collapses repeated slashes", () => {
    expect(normalizeRoute("//foo///bar//")).toBe("/foo/bar");
  });

  test("strips trailing /index", () => {
    expect(normalizeRoute("/foo/index")).toBe("/foo");
    expect(normalizeRoute("/index")).toBe("/");
  });

  test("lowercases", () => {
    expect(normalizeRoute("/Foo/Bar")).toBe("/foo/bar");
  });

  test("root variants normalize to /", () => {
    expect(normalizeRoute("/")).toBe("/");
    expect(normalizeRoute("///")).toBe("/");
  });

  test("decodes percent-encoded but does not double-decode", () => {
    expect(normalizeRoute("/foo%2Fbar")).toBe("/foo/bar");
    // Already-decoded inputs stay stable (idempotent).
    expect(normalizeRoute(normalizeRoute("/foo%2Fbar")!)).toBe("/foo/bar");
  });

  test("rejects empty / whitespace input", () => {
    expect(normalizeRoute("")).toBeNull();
    expect(normalizeRoute("   ")).toBeNull();
  });

  test("rejects malformed percent-encoding", () => {
    expect(normalizeRoute("/foo%ZZ")).toBeNull();
  });

  test("rejects control characters", () => {
    expect(normalizeRoute("/foo\x00bar")).toBeNull();
    expect(normalizeRoute("/foo%00bar")).toBeNull();
  });

  test("non-string inputs", () => {
    // @ts-expect-error testing non-string
    expect(normalizeRoute(null)).toBeNull();
    // @ts-expect-error testing non-string
    expect(normalizeRoute(123)).toBeNull();
  });

  test("very long path stays linear", () => {
    const deep = "/" + Array.from({ length: 500 }, (_, i) => `seg${i}`).join("/");
    const result = normalizeRoute(deep);
    expect(result).toBe(deep.toLowerCase());
  });
});

describe("pickRoute", () => {
  const routes = ["/", "/api", "/api/v1", "/api/v1/users", "/health"];

  test("exact match", () => {
    expect(pickRoute("/health", routes)).toBe("/health");
  });

  test("longest prefix match wins", () => {
    expect(pickRoute("/api/v1/users/42", routes)).toBe("/api/v1/users");
    expect(pickRoute("/api/v1/projects", routes)).toBe("/api/v1");
    expect(pickRoute("/api/other", routes)).toBe("/api");
  });

  test("falls back to root", () => {
    expect(pickRoute("/something/else", routes)).toBe("/");
  });

  test("no match returns null", () => {
    expect(pickRoute("/foo", ["/api", "/health"])).toBeNull();
  });

  test("invalid path returns null", () => {
    expect(pickRoute("", routes)).toBeNull();
  });

  test("does not partial-match within a segment", () => {
    // /api should NOT match /apiary/foo
    expect(pickRoute("/apiary/foo", ["/api"])).toBeNull();
  });
});

describe("joinRoute", () => {
  test("joins simple parts", () => {
    expect(joinRoute("foo", "bar")).toBe("/foo/bar");
    expect(joinRoute("/foo/", "/bar/")).toBe("/foo/bar");
  });

  test("skips null/undefined/empty", () => {
    expect(joinRoute("foo", null, "bar", undefined, "")).toBe("/foo/bar");
  });

  test("all empty returns root", () => {
    expect(joinRoute()).toBe("/");
    expect(joinRoute(null, undefined, "")).toBe("/");
  });

  test("normalizes nested slashes", () => {
    expect(joinRoute("foo/", "/bar", "/baz/qux")).toBe("/foo/bar/baz/qux");
  });
});
