// pure.ts — the parity shim for the pure TypeScript package.
//
//   node ts/conform/pure.ts < requests
//   bun  ts/conform/pure.ts < requests
//
// First line: `HELLO ts pure EDHUFN`; then one response per request.

import { decode, encode, fields, hash32, nodeFrom, unixMs } from "brd14";
import { latin1, serve } from "./protocol.ts";

serve("ts", "pure", {
  E: (ns, snow) => encode(latin1(ns), snow),
  D: (id) => {
    const r = decode(id);
    return `${r.ns} ${r.snow}`;
  },
  H: (k) => hash32(k),
  U: (snow) => unixMs(snow),
  F: (snow) => {
    const f = fields(snow);
    return `${f.ts} ${f.node} ${f.seq}`;
  },
  N: (host, pid) => nodeFrom(host, pid),
});
