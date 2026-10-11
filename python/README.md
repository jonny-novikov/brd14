# brd14 — Python

The pure-Python implementation of **brd14**, a 14-byte branded identity that is **time-ordered**,
**coordination-free**, and **carries its own type**.

```
USR0KHTOWnGLuC
└┬┘└─────┬────┘
 │       └─ 11 chars of base62 over a ts(41) | node(10) | seq(12) snowflake
 └───────── a 3-letter uppercase namespace: the brand IS the type
```

- Standard library only. No native extension, so the same `py3-none-any` wheel runs on CPython
  3.12, 3.13, 3.14 and the **free-threaded 3.14t** build.
- Fully typed (`py.typed`, checked with `mypy --strict`).
- Held to the shared contract by the repository's frozen vectors and a differential parity run
  against an independent oracle.

```bash
pip install ./python        # from a checkout of the repository
```

## Use

```python
from datetime import UTC, datetime

import brd14

g = brd14.Generator(brd14.default_node())   # thread-safe; share one per process

id = g.next_branded("USR")                  # 'USR0KHTOWnGLuC'
ns, snow = brd14.decode(id)                 # ('USR', 274557032793636864)
b = brd14.parse(id)                         # Branded(ns='USR', snow=274557032793636864)
b.datetime, b.node, b.seq                   # the mint instant (UTC-aware), which minter, which step
brd14.is_valid(id)                          # shape + range; never raises
brd14.check("usr0KHTOWnGLuC")               # <ErrorCode.NAMESPACE: 2>
brd14.encode("USR", 274557032793636864)     # 'USR0KHTOWnGLuC'
brd14.hash32(snow)                          # 234878118
brd14.min_for(datetime(2026, 1, 1, tzinfo=UTC))   # lower bound for a time-range scan
```

Sorting ids as plain strings puts them in mint order between milliseconds. Within one
millisecond the order is node-then-sequence, so one generator's stream is strictly ordered and a
merge of several is ordered to the millisecond.

## Errors

Every refusal is an `InvalidIdError` (a `ValueError`) with a `.code`:

| `ErrorCode` | When |
|---|---|
| `LENGTH` (1) | the input is not exactly 14 bytes |
| `NAMESPACE` (2) | the namespace is not exactly 3 bytes `A-Z` |
| `CHARSET` (3) | a payload byte is outside `[0-9A-Za-z]` |
| `RANGE` (4) | the value is outside `[0, 2**63)` |

Precedence is namespace-first: `encode` checks NAMESPACE then RANGE; `decode` checks LENGTH,
NAMESPACE, CHARSET, RANGE. A `str` is classified on its UTF-8 bytes, so `"USR0KHTOWnGLuÉ"`
(14 characters, 15 bytes) is a LENGTH refusal.

## Namespaces are yours

brd14 ships no namespaces and no census. It enforces the *shape* of a namespace and nothing
about its meaning. Plug your policy in with a `Minter`: the gate runs **first**, on the raw
namespace, and whatever it raises reaches you **unchanged** (the same exception object):

```python
census = {"USR", "SES"}

class NotInCensus(Exception):
    pass

def gate(ns: str) -> None:
    if ns not in census:
        raise NotInCensus(f"refusing to mint {ns!r}: not in the census")

m = brd14.Minter(brd14.Generator(brd14.default_node()), gate)
m.mint("USR")                   # 'USR0KHTOWnGLuC'
m.mint("ZZZ")                   # raises NotInCensus, your exception, in your words
m.mint_snowflake("SES")         # ('SES…', 2745570…), the id and the snowflake behind it
```

`gate=None` means *no policy*, never *no validation*. Use `brd14.allow_all` when the openness is
intended and `brd14.deny_all` (raises `NamespaceRefusedError`, which is deliberately **not** an
`InvalidIdError`) while the policy is not wired yet.

## Uniqueness, stated honestly

A `Generator` is strictly monotonic under every clock regime: a burst past 4096 ids/ms borrows
into the timestamp, and a backward clock step keeps minting off the logical clock. It holds a
`threading.Lock` around one integer cell, which is what makes it correct on the free-threaded
build, where threads mint truly in parallel.

Across processes, uniqueness rests on the node field. `default_node()` hashes the hostname and
the pid, so two processes on one host collide with probability about 1/1024 per pair. Pin the
node explicitly when ids must stay attributable to one service, and create generators **after**
`os.fork()`: a forked child inherits its parent's cell and node.

## More

- [docs/python.md](../docs/python.md): the full API, the error model, allocation profile,
  CPython 3.14 vs 3.14t, and measured numbers.
- [docs/contract.md](../docs/contract.md): the normative contract.

MIT licensed.
