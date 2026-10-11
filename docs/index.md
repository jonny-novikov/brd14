# brd14 documentation

Agents: start with [AGENTS.md](../AGENTS.md) (where) and [CLAUDE.md](../CLAUDE.md) (how).

| Page | What you get from it |
|---|---|
| [contract.md](contract.md) | **Normative.** The format, operations, error precedence, vectors schema, parity protocol, WASM ABI, and the reserved format family (brd15/brd16). |
| [architecture.md](architecture.md) | How the repository is laid out, the variant taxonomy (pure · speed · memory), and how the pieces depend on each other. |
| [environment.md](environment.md) | The pinned toolchains, how they are installed, and the SessionStart hook. |
| [go.md](go.md) | The Go reference: API, zero-allocation guarantees and how they are proven. |
| [c.md](c.md) | The C cores: speed vs memory, footprint, the ABI, tests, benches, fuzzing. |
| [rust.md](rust.md) | The Rust workspace: `no_std` core, FFI drop-in, the wasm crate. |
| [beam.md](beam.md) | The Erlang NIF and how to build it against either core. |
| [python.md](python.md) | The pure-Python package, CPython 3.14 and free-threaded 3.14t specifics. |
| [typescript.md](typescript.md) | The pure TypeScript package: exact 64-bit arithmetic without BigInt. |
| [wasm.md](wasm.md) | The TypeScript-over-WebAssembly package: ABI, loader, batching. |
| [runtimes.md](runtimes.md) | Runtime specifics side by side: Node 24 vs Bun 1.4, CPython 3.14 vs 3.14t, Go 1.26. |
| [parity.md](parity.md) | How agreement across implementations is proven, and the latest matrix. |
| [benchmarks.md](benchmarks.md) | Measured numbers, the protocol behind them, and how to reproduce them. |
| [hardening.md](hardening.md) | Sanitizers, Miri, fuzzing, race detection, floor toolchains. |
| [elixir.md](elixir.md) | `ex/echo_data`: the BEAM implementation, standalone on Elixir ≥ 1.14, and how it is proven. |
| [structures.md](structures.md) | **Normative** for the structures extension: the champ's exact shape and digest, Tree and Buckets behaviour, the vectors. |
| [kan/brd14-pragmatic-guide.md](kan/brd14-pragmatic-guide.md) | The pragmatic programmer's guide as one KAN story: layout profiles, branded structures, the NIF, decisions and rungs. |
| [roadmap.md](roadmap.md) | What is done, what is next — implementation, measurement, CI — and the open decisions. |
| [cli.md](cli.md) | The shell tools: `brd` and `mint`, the `.brdrc` settings file, recipes. |
