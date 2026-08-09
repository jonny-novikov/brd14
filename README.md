# brd14

A 14-byte branded identity for Go: **time-ordered**, **coordination-free**, and carrying its own type.

```
USR0KHTOWnGLuC
└┬┘└─────┬────┘
 │       └─ 11 chars of Base62 over a ts(41)|node(10)|seq(12) snowflake
 └───────── a 3-letter uppercase namespace — the brand IS the type
```

```bash
go get github.com/jonny-novikov/brd14
```

No dependencies. Standard library only.

## Use

```go
g := brd14.NewGenerator(brd14.DefaultNode())

id, err := g.NextBranded("USR")        // "USR0KHTOWnGLuC"
ns, snow, err := brd14.Parse(id)       // "USR", 274557032793636864
brd14.Time(snow)                       // the mint instant
brd14.NodeOf(snow), brd14.SeqOf(snow)  // which minter, which step
brd14.Valid(id)                        // shape + range, total, never panics
```

Sorting a slice of ids as plain strings puts them in mint order — see
[Ordering](#ordering-stated-honestly) for the exact guarantee.

## Namespaces are yours

brd14 ships **no namespaces and no census**. Which three-letter brands exist, what they mean, and
which of them a service may mint are policy, and policy belongs to the consumer. `Encode` and
`Parse` enforce the *shape* of a namespace (three bytes of `A-Z`) and nothing about its meaning:
`ZZZ` is well-formed here and may be unregistered in your system.

Plug your policy in with a `Gate`:

```go
var census = map[string]bool{"USR": true, "SES": true}

g := brd14.NewGenerator(brd14.DefaultNode())
m := brd14.NewMinter(g, func(ns string) error {
    if !census[ns] {
        return fmt.Errorf("refusing to mint %q: not in the census", ns)
    }
    return nil
})

id, err := m.Mint("USR")   // "USR0KHTOWnGLuC"
_, err = m.Mint("ZZZ")     // your error, in your words — returned unchanged
```

The gate runs **first**, so a namespace that is both off-policy and malformed is reported as the
policy problem it is. A `nil` gate means *no policy* — every well-formed namespace is admitted. It
does not mean no validation: `zz1` is still refused on shape. Ship `AllowAll` when the openness is
intended and `DenyAll` when the policy is not yet wired.

`NewMinter` takes a `*Generator` rather than a node id, so a service that already owns one — because
it also mints bare snowflakes, or its existing helper is written against one — gates *that*
generator instead of running a second one beside it.

`MintSnowflake` returns the id *and* the snowflake behind it, for callers that report decoded
fields without parsing back an id they just minted.

## The contract

| | |
|---|---|
| Length | 14 bytes, fixed. `3 × [A-Z]` + 11 × Base62 |
| Alphabet | `0-9A-Za-z` — **ASCII order**, so lexicographic order equals numeric order |
| Layout | `ts(41) << 22 \| node(10) << 12 \| seq(12)` |
| Epoch | `1704067200000` — 2024-01-01T00:00:00Z |
| Domain | `[0, 2^63)`. The payload never exceeds `AzL8n0Y58m7`; `USRzzzzzzzzzzz` is **refused, not wrapped** |
| Errors | one sentinel, `ErrInvalid`. Compare with `errors.Is` |

**Fourteen bytes is permanent.** It is a public contract, not a current implementation — namespace
pressure resolves in data (a registered census), never in width.

The same contract is implemented independently in Elixir, Rust, C and TypeScript. Those
implementations share no code with this one; they share the frozen vectors in `contract_test.go`
(`Encode("USR", 274557032793636864) == "USR0KHTOWnGLuC"`, `Hash32(274557032793636864) == 234878118`,
and the exact `AzL8n0Y58m7` ceiling). Within Go the contract now travels as this package. The
vectors stay, because they are what proves the two forms still agree.

## Ordering, stated honestly

Byte-sorting ids reproduces mint order **between milliseconds**: the timestamp is the high field,
and a fixed-width Base62 body compares lexicographically exactly as the snowflake compares
numerically. That is what makes `MinFor(t)` a usable cursor for time-range scans.

**Within a single millisecond the ordering is node-then-seq.** Two ids minted in the same
millisecond on *different* nodes do not sort by mint order. One minter's stream is always strictly
ordered; a merge of several is ordered to millisecond granularity. `TestTsMajorOrdering` states
this as the contract rather than letting the stronger-sounding claim stand.

## Uniqueness, stated honestly

A `Generator` is strictly monotonic under every clock regime. It is lock-free — one atomic cell
holding `ts<<12|seq`, advanced by CAS to `max(now, last+1)`:

- **burst** past 4096 ids/ms — the carry borrows into the timestamp rather than blocking, so a
  sustained overload runs at most a few milliseconds ahead;
- **clock regression** — minting continues off the logical clock. No duplicates, no sleeping.

Across processes, uniqueness rests on the node field. `DefaultNode()` derives it from FNV-32a over
the hostname followed by the ASCII-decimal pid, masked to 10 bits, so two processes on one host
almost always differ — with a **residual collision of about 1 in 1024 per same-host process pair**.
That residual is load-independent and never zero: budgetable, not absent. A service whose ids must
stay attributable to it should pin its node explicitly rather than derive one.

## License

MIT
