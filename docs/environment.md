# Environment

## The pinned set

One file, [`scripts/versions.env`](../scripts/versions.env), names every toolchain version. The
setup script, the env file, the Rust toolchain pin and the CI image (`fly/Dockerfile`) all read from it.

| Tool | Version | Why this one |
|---|---|---|
| Go | 1.26.9 | Development and CI toolchain. The module's `go` line stays at **1.22.0**, the honest minimum for consumers. The full tier fetches 1.22.12 to prove that floor. |
| Python | 3.14 and 3.14t | 3.14 is the target. 3.14t is the free-threaded build, which proves the generator is correct without a GIL. 3.12 and 3.13 are tested in CI (`scripts/ci.sh python`). |
| Node | 24.21.0 "Krypton" | The latest LTS line. It runs `.ts` sources directly through built-in type stripping. |
| Bun | 1.4.3 | The second JS runtime. It runs `.ts` natively and has its own test runner. |
| Rust | 1.99.0 + `wasm32-unknown-unknown` | Pinned again in [`native/rust/rust-toolchain.toml`](../native/rust/rust-toolchain.toml). Nightly is used only for Miri and cargo-fuzz (full tier). |
| Erlang/OTP + Elixir | OTP 25.3 + Elixir 1.14.0 (Ubuntu packages) | The floor `ex/echo_data` is held to; the echo umbrella itself runs Elixir 1.18.4 / OTP 28, which CI also exercises. Hex comes from `repo.hex.pm`. |
| C | gcc 13.3, clang 18 (system) | Matches the pinned EchoMQ bench (Ubuntu 24.04 / gcc 13.3). clang supplies libFuzzer through `libclang-rt-18-dev`. |
| PostgreSQL | 16 | Used only by the storage probe (`tools/storage_probe/`). |

## Installing

```bash
scripts/setup.sh          # core: Go, Python 3.14/3.14t, Node, Bun, Rust (+wasm32), OTP + Elixir, per-tree deps
scripts/setup.sh full     # + Go floor toolchain, Rust nightly/Miri, libFuzzer runtime, PostgreSQL 16
. scripts/env.sh          # GOTOOLCHAIN + PATH for the current shell
```

Every step checks the pinned version first and skips when it is already present. A cold container
takes about 80 s for the full tier; a warm one about 0.1 s.

The install sources are the ones the Claude Code cloud egress proxy allows:

| Toolchain | Source |
|---|---|
| Go | `proxy.golang.org`, through `GOTOOLCHAIN` |
| Python | the deadsnakes PPA |
| Node | `nodejs.org` |
| Bun | the npm registry (the `bun` package) |
| Rust | `static.rust-lang.org`, through rustup |
| Erlang/OTP, Elixir | the Ubuntu archive (apt); Hex packages from `repo.hex.pm` |

GitHub release downloads are blocked there. That is why the script installs neither
`uv python install` (python-build-standalone) nor `bun.sh/install`.

## Claude Code cloud sessions

[`.claude/settings.json`](../.claude/settings.json) registers a **SessionStart** hook for new
sessions (`startup`). [`.claude/hooks/session-start.sh`](../.claude/hooks/session-start.sh) runs
only when `CLAUDE_CODE_REMOTE=true`. It does two things:

- runs `scripts/setup.sh core`;
- appends `. scripts/env.sh` to `$CLAUDE_ENV_FILE`, so every command in the session sees the pinned
  toolchains.

The hook is **synchronous**, so a session never starts before its toolchains exist. The container
snapshot is cached after the hook runs, which keeps later sessions on the warm path.
