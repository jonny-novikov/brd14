// wasm.ts — the parity shim for brd14-wasm (the Rust core over WebAssembly).
//
//   node ts/conform/wasm.ts < requests
//   bun  ts/conform/wasm.ts < requests
//
// First line: `HELLO ts wasm EDH`. Only the operations the wasm module itself
// performs are declared: encode, decode and hash32 cross the ABI; the field
// readers and node derivation are the pure package's code, already covered by
// pure.ts, so declaring them here would test nothing new.

import { decode, encode, hash32 } from "brd14-wasm";
import { latin1, serve } from "./protocol.ts";

serve("ts", "wasm", {
  E: (ns, snow) => encode(latin1(ns), snow),
  D: (id) => {
    const r = decode(id);
    return `${r.ns} ${r.snow}`;
  },
  H: (k) => hash32(k),
});
