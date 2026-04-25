import { describe, expect, test } from "bun:test";
import {
  isAgentTier,
  isFeatureEnabled,
  parseSchedule,
  retryDelayMs,
  selectAgentTier,
} from "../agents-internal";
import { agents } from "../agents";

describe("agents registry", () => {
  test("exposes the expected tier names", () => {
    expect(Object.keys(agents).sort()).toEqual(
      ["cheapFast", "frontendcheap", "reviewSmart", "smart", "smartTool"].sort()
    );
  });

  test("each tier has at least one agent", () => {
    for (const [tier, list] of Object.entries(agents)) {
      expect(Array.isArray(list)).toBe(true);
      expect(list.length).toBeGreaterThan(0);
    }
  });
});

describe("selectAgentTier", () => {
  test("default is cheapFast", () => {
    expect(selectAgentTier()).toBe("cheapFast");
    expect(selectAgentTier({})).toBe("cheapFast");
  });

  test("review takes priority over tools", () => {
    expect(selectAgentTier({ needsReview: true, needsTools: true })).toBe("reviewSmart");
  });

  test("tools selected when no review", () => {
    expect(selectAgentTier({ needsTools: true })).toBe("smartTool");
  });

  test("frontendOnly when no other flags", () => {
    expect(selectAgentTier({ frontendOnly: true })).toBe("frontendcheap");
  });

  test("frontendOnly is overridden by tools/review", () => {
    expect(selectAgentTier({ frontendOnly: true, needsTools: true })).toBe("smartTool");
    expect(selectAgentTier({ frontendOnly: true, needsReview: true })).toBe("reviewSmart");
  });
});

describe("isAgentTier", () => {
  test("known tiers", () => {
    expect(isAgentTier("smart")).toBe(true);
    expect(isAgentTier("cheapFast")).toBe(true);
  });

  test("unknown / non-string", () => {
    expect(isAgentTier("bogus")).toBe(false);
    expect(isAgentTier("")).toBe(false);
    expect(isAgentTier(null)).toBe(false);
    expect(isAgentTier(undefined)).toBe(false);
    expect(isAgentTier(42)).toBe(false);
  });
});

describe("isFeatureEnabled", () => {
  test("truthy values", () => {
    expect(isFeatureEnabled({ FOO: "1" }, "FOO")).toBe(true);
    expect(isFeatureEnabled({ FOO: "true" }, "FOO")).toBe(true);
    expect(isFeatureEnabled({ FOO: "TRUE" }, "FOO")).toBe(true);
    expect(isFeatureEnabled({ FOO: "yes" }, "FOO")).toBe(true);
    expect(isFeatureEnabled({ FOO: "on" }, "FOO")).toBe(true);
    expect(isFeatureEnabled({ FOO: "  true  " }, "FOO")).toBe(true);
  });

  test("falsy values", () => {
    expect(isFeatureEnabled({ FOO: "0" }, "FOO")).toBe(false);
    expect(isFeatureEnabled({ FOO: "false" }, "FOO")).toBe(false);
    expect(isFeatureEnabled({ FOO: "" }, "FOO")).toBe(false);
    expect(isFeatureEnabled({ FOO: "no" }, "FOO")).toBe(false);
    expect(isFeatureEnabled({ FOO: "off" }, "FOO")).toBe(false);
    expect(isFeatureEnabled({ FOO: undefined }, "FOO")).toBe(false);
  });

  test("missing flag / empty key", () => {
    expect(isFeatureEnabled({}, "MISSING")).toBe(false);
    expect(isFeatureEnabled({ FOO: "1" }, "")).toBe(false);
  });
});

describe("retryDelayMs", () => {
  test("attempt 0 is base delay", () => {
    expect(retryDelayMs(0, 100, 10_000)).toBe(100);
  });

  test("doubles each attempt", () => {
    expect(retryDelayMs(1, 100, 10_000)).toBe(200);
    expect(retryDelayMs(2, 100, 10_000)).toBe(400);
    expect(retryDelayMs(3, 100, 10_000)).toBe(800);
  });

  test("caps at maxMs", () => {
    expect(retryDelayMs(20, 100, 5_000)).toBe(5_000);
  });

  test("invalid attempts return 0", () => {
    expect(retryDelayMs(-1)).toBe(0);
    expect(retryDelayMs(NaN)).toBe(0);
    expect(retryDelayMs(Infinity)).toBe(0);
  });

  test("invalid base/max return 0", () => {
    expect(retryDelayMs(2, 0, 1000)).toBe(0);
    expect(retryDelayMs(2, 100, 0)).toBe(0);
    expect(retryDelayMs(2, -1, 1000)).toBe(0);
  });

  test("very large attempt does not overflow / NaN", () => {
    const v = retryDelayMs(1_000_000, 100, 30_000);
    expect(v).toBe(30_000);
    expect(Number.isFinite(v)).toBe(true);
  });

  test("fractional attempt is floored", () => {
    expect(retryDelayMs(2.9, 100, 100_000)).toBe(400);
  });
});

describe("parseSchedule", () => {
  test("happy paths", () => {
    expect(parseSchedule("500ms")).toBe(500);
    expect(parseSchedule("1s")).toBe(1_000);
    expect(parseSchedule("5m")).toBe(300_000);
    expect(parseSchedule("2h")).toBe(7_200_000);
    expect(parseSchedule("1d")).toBe(86_400_000);
  });

  test("whitespace and case insensitive", () => {
    expect(parseSchedule("  10S ")).toBe(10_000);
    expect(parseSchedule("3 H")).toBe(3 * 3_600_000);
  });

  test("zero is valid", () => {
    expect(parseSchedule("0s")).toBe(0);
  });

  test("invalid inputs return null", () => {
    expect(parseSchedule("")).toBeNull();
    expect(parseSchedule("   ")).toBeNull();
    expect(parseSchedule("abc")).toBeNull();
    expect(parseSchedule("5x")).toBeNull();
    expect(parseSchedule("-1s")).toBeNull();
    expect(parseSchedule("1.5s")).toBeNull();
    // @ts-expect-error testing non-string input
    expect(parseSchedule(null)).toBeNull();
    // @ts-expect-error testing non-string input
    expect(parseSchedule(undefined)).toBeNull();
  });
});
