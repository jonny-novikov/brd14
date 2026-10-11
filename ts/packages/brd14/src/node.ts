// brd14/node — the host-derived default node id. Kept out of the main entry so
// the core stays free of platform modules; `node:os` and `process` are
// available on Node and Bun alike.

import { hostname } from "node:os";
import { nodeFrom } from "./codec.ts";

/**
 * A coordination-free node id (0..1023) from the hostname and the pid: distinct
 * per process on one host up to the ~1/1024 masked-hash residual the contract
 * documents. A hostname failure hashes the pid alone.
 */
export function defaultNode(): number {
  let host = "";
  try {
    host = hostname();
  } catch {
    host = "";
  }
  return nodeFrom(host, process.pid);
}
