# Elixir: `ex/echo_data`

`echo_data` is the BEAM implementation of brd14 and of the [branded structures](structures.md). It
was imported verbatim from the fiberfx `echo` umbrella (branch `kan`, commit `24a4083`, path
`echo/apps/echo_data`), where it is the pure base of the BCS data-layer stack. Here it stands alone
and is held to the same proof as every other tree.

| | |
|---|---|
| Runtime floor | Elixir 1.14, Erlang/OTP 25 (the umbrella itself pins Elixir 1.18.4 / OTP 28) |
| Runtime dependencies | none; `stream_data` for tests only |
| Native code | optional; `EchoData.Native` loads `priv/` NIF when present and falls back to pure Elixir |
| Proof | its own suite (doctests, properties, `vectors/*.tsv` replayed) and the parity shim `ex-pure` (`ex-nif` once the NIF ships) |

## Build and test

```bash
make -C ex test        # compile --warnings-as-errors, then mix test
make -C ex harden      # mix format --check-formatted, no compile-time cycles, suite under a fixed seed
make -C ex bench       # the structures bench -> bench/results/
```

Run `mix` with `TMPDIR=/tmp` (the targets do), as the umbrella guide advises: a small tmp overlay
otherwise surfaces as spurious mid-suite I/O failures.

## What changed from the umbrella copy

The import commit is byte-for-byte; every later change is its own reviewable commit.

| Change | Why |
|---|---|
| `mix.exs` without `../../` build, config, deps and lockfile paths; `elixir: "~> 1.14"`; Hex package metadata | stands alone, runs on the Elixir this environment ships, and can be packaged |
| `native/` (a C shim over a vendored copy of a Rust core) removed | one source of truth for the cores; replaced by one Rustler NIF built from this repository's crates |
| `priv/census.vectors` tracked | the root `.gitignore` ignored `priv/`, so a fresh checkout failed the census drift gate |
| six files run through `mix format` | they exceeded the formatter's line limit upstream |

## Where it agrees with the contract, and where it does not (yet)

| Contract item | echo_data | Shim op |
|---|---|---|
| encode, decode, precedence | `BrandedId.encode/2`, `BrandedId.parse/1`; error classes via `BrandedId.validate/1` | `E`, `D` |
| `hash32` | `BrandedId.hash32/1` | `H` |
| `unix_ms`, fields | `Snowflake.unix_ms/1`, `node_id/1`, `sequence/1` | `U`, `F` |
| node derivation | default `phash2(node())` (kept for running fleets); the contract's FNV derivation is `Snowflake.node_from/2` | `N` |
