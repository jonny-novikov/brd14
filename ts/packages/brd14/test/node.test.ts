// node.test.ts — the brd14/node subpath on Node and Bun.

import { hostname } from "node:os";
import { describe, expect, test } from "vitest";
import { nodeFrom } from "brd14";
import { defaultNode } from "brd14/node";

describe("brd14/node", () => {
  test("defaultNode is node_from(hostname, pid), within 10 bits", () => {
    const n = defaultNode();
    expect(Number.isInteger(n) && n >= 0 && n <= 1023).toBe(true);
    expect(n).toBe(nodeFrom(hostname(), process.pid));
    expect(defaultNode()).toBe(n);
  });
});
