# Hardening

What each tree does beyond its unit tests. Every result below is from a run during the build-out;
`make harden` re-runs all of them.

| Tree | Check | Result |
|---|---|---|
| Go | `go test -race`; the suite on the **go1.22.12 floor**; native fuzz `FuzzParse` and `FuzzAppendEncode` (10 s each), checked against an independent `math/big` model | clean. 823k and 674k execs |
| Go | `testing.AllocsPerRun` gate, 50 cases | 0 allocs on every hot path and every refusal path. A mutation (wrapping one refusal in `fmt.Errorf`) makes it fail |
| C | ASan + UBSan (`-fno-sanitize-recover=all`); `_FORTIFY_SOURCE=3` + stack protector; `-Wconversion -Wsign-conversion -Wpedantic -Werror` with gcc 13.3 and clang 18 | clean |
| C | `make gates`: zero `div`/`idiv` in either core (proved non-vacuous on a probe build); `nm -u` (speed needs `memcmp`, memory needs nothing); `size -A` | speed 8,063 B rodata, memory **0** |
| C | libFuzzer: `fuzz_decode` (totality, speed vs memory vs reference, round-trip) and `fuzz_encode`, 30 s each | 21.5M and 18.1M execs, 0 findings, 100% region coverage of both cores |
| C | mutation testing of the memory core | 7 of 8 mutants killed by the suite; the 8th (`RB+1`) fails to compile because of a `_Static_assert` |
| Rust | clippy `-D warnings` on every configuration; `rustfmt --check` | clean |
| Rust | **Miri** (nightly): the core, plus ffi and wasm under `-Zmiri-strict-provenance` and Tree Borrows | clean |
| Rust | cargo-fuzz `decode_differential` and `encode_differential`, about 30 s each | 20.3M and 19.0M runs, 0 findings |
| Rust | `alloc-check`: `nm -u` on `libbrd14_ffi.{so,a}` | no allocator and no libc imports in our own code |
| Python | 3.14t with the GIL disabled: full suite under `-X dev -W error`, then the 8 threads × 50k shared-generator stress test, 5 rounds; `mypy --strict` | clean. An *unlocked* generator produced 187k–260k duplicates per 400k mints on 3.14t, which is why the lock exists |
| TS | strict typecheck (TS 7.0.2); grep gate (no `vi.`); `node --frozen-intrinsics --disable-proto=throw` smoke; same suite on vitest (Node) and `bun test` (Bun) | clean: 72/72 on both runtimes |
| BEAM | `make -C native/beam check`: compiles against a stub `erl_nif.h` (no ERTS here) and link-checks the NIF against c-speed, c-memory and the Rust `libbrd14_ffi.so` | the NIF exports `nif_init` alone and leaves only 9 `enif_*` symbols to ERTS |
