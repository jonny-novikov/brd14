# TypeScript over WebAssembly

> **Status: in progress.** The Rust side is done and verified. The TypeScript package is
> partially built on branch `worktree-agent-aac67ed67b61286d4` (commit `0d61f03`: build pipeline,
> sync loader, codec API). Tests, the parity shim, the bench and this page's full content come
> next; see [roadmap.md](roadmap.md).

## What exists and is verified

- **The module:** [`native/rust/crates/brd14-wasm`](../native/rust/crates/brd14-wasm/). It
  implements [the WebAssembly ABI](contract.md#the-webassembly-abi-nativerustcratesbrd14-wasm)
  exactly:
  - no imports and no allocator;
  - memory fixed at 3 pages, so `grow` fails and JS views never detach;
  - a static 64 KiB IO region;
  - batch calls clamped to 2,978.
- **Size:** speed core **10,019 B**, memory core **2,639 B**.
- **Default:** the speed core, by measurement. In Node 24, the speed core's `encode_many` takes
  6.5 ns per id and `decode_many` 8.9 ns per id, against 19.6 and 25.1 ns for the memory core:
  about 3× faster for 7.4 KB more.
- `crates/brd14-wasm/check.mjs` drives the raw exports from Node. It checks the vectors V-1..V-6,
  every row of `valid.tsv`, `invalid.tsv` and `encode_invalid.tsv`, and both batch exports over
  the whole corpus. It runs as part of `make -C native/rust test`.

## Design of the TypeScript package

- No wasm-bindgen.
- The `.wasm` is embedded as base64 in a generated, gitignored module and decoded with `atob`.
- It is instantiated synchronously, once, so Node and Bun share one code path with no
  `await init()`.
- `Generator`, `Minter` and the errors are reused from the pure `brd14` package.
- JS values map onto the ABI as follows:
  - the namespace is packed little-endian;
  - a BigInt outside `[0, 2^63)` is passed as `-1`, so wasm applies namespace-then-range
    precedence;
  - string ids are classified on their UTF-8 bytes, exactly like the pure package.
