# The BEAM NIF

[`native/beam/echo_native.c`](../native/beam/echo_native.c) is the Erlang NIF behind
`EchoData.Native` (`Elixir.EchoData.Native`). It covers the codec and the hash, nothing else, and
runs over any brd14 core that exports the C ABI in
[`native/include/branded_id.h`](../native/include/branded_id.h):

| `CORE=` | What gets linked | Runtime files in `priv/` | Build needs |
|---|---|---|---|
| `rust` (default) | the Rust `brd14-ffi` crate, as a shared library | `echo_native.so`, `libbrd14_ffi.so` | ERTS headers, cargo |
| `c-speed` | [the C speed core](c.md#the-speed-core), compiled into the NIF at `-O2` | `echo_native.so` | ERTS headers, a C11 compiler |
| `c-memory` | [the C memory core](c.md#the-memory-core), compiled into the NIF at `-Os` | `echo_native.so` | ERTS headers, a C11 compiler |

The NIF source is identical for every core. The parity run holds every core to the same oracle,
so the choice changes footprint and speed, not answers.

## The NIF functions

| Function | Arguments | Returns |
|---|---|---|
| `hash32/1` | `key`: an integer in `[0, 2^64)` | the hash as an integer in `[0, 2^32)` |
| `decode/1` | `id`: a binary | `{ns, snow}`, with `ns` a 3-byte binary and `snow` an integer; or `:error` |
| `decode_hash/1` | `id`: a binary | `{ns, snow, hash32(snow)}`; or `:error` |
| `encode/2` | `ns`: a 3-byte binary; `snow`: an integer in `[0, 2^64)` | the 14-byte id; or `:error` |

An argument of the wrong *type* raises `ArgumentError` (`badarg`). That covers a non-binary, an
integer outside `[0, 2^64)`, or a namespace binary that is not exactly 3 bytes. A well-typed value
that the contract refuses returns `:error`.

### The `:error` collapse

The cores distinguish four refusal classes ([contract](contract.md#errors-and-precedence)). The
NIF maps all of them to the single atom `:error`, because the Elixir API it backs returns
`{:ok, _} | :error` and the hot path has no use for the class.

| Contract class | `decode/1`, `decode_hash/1` | `encode/2` |
|---|---|---|
| `LENGTH` (not 14 bytes) | `:error` | not applicable |
| `NAMESPACE` | `:error` | `:error` for 3 bytes outside `A-Z`; **`badarg`** for a namespace of any other length |
| `CHARSET` | `:error` | not applicable |
| `RANGE` | `:error` | `:error` for `snow` in `[2^63, 2^64)`; `badarg` from `2^64` up, or below 0 |

The `badarg` for a namespace of the wrong length is long-standing NIF behaviour, and it is kept. The
contract classes that case as `NAMESPACE`. The C ABI cannot see a length, so the check has to happen
before the call, and this NIF happens to report it as an argument error. An Elixir wrapper that
wants contract-exact classes should guard `byte_size(ns) == 3` itself and return its own error.
A caller that needs the class itself should use the pure Elixir implementation, or a future
`decode_detailed/1` returning `{:error, :length | :namespace | :charset | :range}`.

## Building

When brd14 is vendored, its `native/` folder becomes the app's `native/`. The Makefile defaults
to `PRIV ?= ../../priv`, which is the app's own `priv/`:

```
my_app/
├── native/                 ← brd14's native/ folder, vendored
│   ├── beam/               ← run make here
│   ├── c/   include/   rust/
└── priv/
    ├── echo_native.so
    └── libbrd14_ffi.so     (CORE=rust only)
```

```bash
cd native/beam
make                  # CORE=rust: cargo build --release -p brd14-ffi, copy the .so, link the NIF
make CORE=c-speed     # the C speed core inside echo_native.so
make CORE=c-memory    # the C memory core inside echo_native.so
make check            # works without Erlang installed (see below)
make clean
```

**ERTS headers.** The Makefile asks the `erl` on `PATH` for `<root>/erts-<vsn>/include`. To point it
somewhere else, set `ERTS_INCLUDE=/path/to/erts-X/include`. Without real headers, `make` stops with a
message, because a NIF compiled against anything else must not be loaded.

**CORE=rust.** The Makefile runs `cargo build --release -p brd14-ffi` in `../rust`, then copies
`../rust/target/release/libbrd14_ffi.so` into `PRIV`. It links `echo_native.so` with
`-L$(PRIV) -lbrd14_ffi -Wl,-rpath,'$ORIGIN'`. The result records `NEEDED libbrd14_ffi.so` and
`RUNPATH $ORIGIN`, so the dynamic loader looks for the library next to `echo_native.so`, wherever
a release puts `priv/`. Keep the two files together.

**CORE=c-speed / c-memory.** The chosen core is compiled at its own optimisation level, with
`-fvisibility=hidden`, and linked into `echo_native.so`. The NIF then exports `nif_init` alone. The
core's `branded_*` symbols bind inside the library, so they can neither interpose on nor be
interposed by another library that carries the same ABI. There is no runtime dependency, and a
stale `libbrd14_ffi.so` in `PRIV` is removed.

**Switching cores.** A stamp file (`build/core.stamp`) records the last `CORE`, so `make CORE=...`
relinks when the core changes and does nothing otherwise. An unknown `CORE` is an error.

### From Mix (sketch)

The repository does not contain the Elixir app. With [`elixir_make`](https://hex.pm/packages/elixir_make),
the wiring looks like this:

```elixir
# mix.exs
def project do
  [
    app: :echo_data,
    compilers: [:elixir_make] ++ Mix.compilers(),
    make_cwd: "native/beam",
    make_env: %{"CORE" => System.get_env("BRD14_CORE", "rust")},
    # ...
  ]
end
```

### `make check` without Erlang

CI machines and this repository's sandbox have no ERTS, so `make check` runs in two stages.

1. **Compile check.** `echo_native.c` is compiled `-fsyntax-only` under
   `-std=c11 -Wall -Wextra -Werror`. The real ERTS headers are used when an `erl` is found.
   Otherwise the build uses [`native/beam/stub/erl_nif.h`](../native/beam/stub/erl_nif.h). That
   file is clearly marked **CI syntax check only**: it declares exactly the subset the NIF uses, with
   the real shapes on LP64, and is not ABI-compatible with ERTS.
2. **Link check.** For each core available (`c-speed`, `c-memory`, and `rust` once
   `libbrd14_ffi.so` is built), it builds a throwaway shared object under `build/check/` that is
   never loaded. It then requires that only `enif_*` symbols, which ERTS provides, plus libc's, are
   left undefined. It also requires that `nif_init` is exported.

On this repository's host:

```
ok   beam: echo_native.c compiles against stub/erl_nif.h (no ERTS here; syntax check only)
ok   beam: NIF links against c-speed (9 enif_* left for ERTS)
ok   beam: NIF links against c-memory (9 enif_* left for ERTS)
skip beam: rust link check (../rust/target/release/libbrd14_ffi.so not built)
```

## Using it from Elixir

The NIF is optional, and the app runs without it (pure Elixir fallback). This is the module shape
it plugs into. The module lives in the echo_data app, not here:

```elixir
defmodule EchoData.Native do
  @moduledoc false
  @on_load :load_nif

  def load_nif do
    path = :filename.join(:code.priv_dir(:echo_data), ~c"echo_native")
    # :ok, or {:error, _} when the library is absent; either way the module loads
    _ = :erlang.load_nif(path, 0)
    :ok
  end

  def hash32(_key), do: :erlang.nif_error(:nif_not_loaded)
  def decode(_id), do: :erlang.nif_error(:nif_not_loaded)
  def decode_hash(_id), do: :erlang.nif_error(:nif_not_loaded)
  def encode(_ns, _snow), do: :erlang.nif_error(:nif_not_loaded)
end
```

```elixir
iex> EchoData.Native.encode("USR", 274557032793636864)
"USR0KHTOWnGLuC"
iex> EchoData.Native.decode("USR0NgWEfAEJfs")
{"USR", 320636799581945856}
iex> EchoData.Native.decode_hash("USR0KHTOWnGLuC")
{"USR", 274557032793636864, 234878118}
iex> EchoData.Native.decode("USRzzzzzzzzzzz")    # RANGE
:error
iex> EchoData.Native.encode("usr", 0)             # NAMESPACE
:error
iex> EchoData.Native.encode("US", 0)              # not a 3-byte namespace
** (ArgumentError) argument error
```

`decode/1` accepts sub-binaries (`enif_inspect_binary`), so an id sliced out of a larger frame needs
no copy. Results are heap binaries (3 or 14 bytes, well under the 64-byte refc threshold) built
directly on the calling process's heap.

## Scheduler notes

- **Normal schedulers are right.** A NIF should return within about 1 ms. Each of these calls
  spends 1–30 ns in the core ([measured](c.md#benchmarks)), plus term decoding and construction,
  so the whole call is well under a microsecond. Dirty schedulers, `enif_consume_timeslice` and
  yielding would all cost more than the work itself.
- **Thread safety.** The cores are reentrant: no globals, no locks, no allocation. `atom_error` is
  created once in `load/3`, and atoms are VM-global, so any scheduler may run any of these NIFs
  concurrently.
- **No resources, no reload state.** `priv_data` is unused, and the NIF needs no `upgrade` or
  `unload` callbacks.

## Future: batch NIFs

For bulk work, such as decoding a page of ids from a database row set or encoding a batch of
minted snowflakes, a per-id NIF call is dominated by call overhead. The natural extension mirrors
the wasm ABI's batch exports ([contract](contract.md#the-webassembly-abi-nativerustcratesbrd14-wasm)):

| Proposed NIF | Input | Output |
|---|---|---|
| `decode_many/1` | one binary of `n × 14` bytes | a binary of `n` big-endian u64s plus the namespaces, or a list of tuples; the count decoded before the first refusal |
| `encode_many/2` | a 3-byte namespace and a binary of `n` u64s | one binary of `n × 14` bytes; the count encoded before the first refusal |

Two design rules carry over from the scalar NIFs:

- **Return binaries, not lists**, so the result is a single allocation.
- **Respect the timeslice.** At 10–30 ns per id, about 20,000–50,000 ids fit in the 1 ms budget.
  Past that, a batch should report progress with `enif_consume_timeslice` and reschedule itself
  with `enif_schedule_nif`, or it should be registered as `ERL_NIF_DIRTY_JOB_CPU_BOUND`. For large
  batches, the memory core's lack of tables leaves the cache lines to the data being decoded.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `{:error, {:load_failed, ~c"...libbrd14_ffi.so: cannot open shared object file..."}}` | `CORE=rust` and the library is not next to `echo_native.so`. The NIF looks in `$ORIGIN`, so ship both files in `priv/`. |
| `{:error, {:load_failed, ~c"...: undefined symbol: branded_..."}}` | A NIF linked for `rust` loaded a library without the ABI, or a stale `echo_native.so`. Run `make clean`, then `make CORE=...`. |
| `make` says "ERTS headers not found" | No `erl` on `PATH`. Install Erlang/OTP, or set `ERTS_INCLUDE`. |
| `{:error, {:bad_lib, ...NIF library version...}}` | The NIF was built against a different ERTS major version. Rebuild against the runtime's headers. |
