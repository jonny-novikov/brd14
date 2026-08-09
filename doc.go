// Package brd14 implements the BCS branded-identity contract: a 14-byte,
// time-ordered, coordination-free id that carries its own type.
//
//	USR0KHTOWnGLuC
//	└┬┘└─────┬────┘
//	 │       └─ 11 chars of Base62 over a ts(41)|node(10)|seq(12) snowflake
//	 └───────── a 3-letter uppercase namespace: the brand IS the type
//
// The epoch is 2024-01-01T00:00:00Z. The snowflake's domain is [0, 2^63) — an
// int64, not a full uint64 — so the payload never exceeds "AzL8n0Y58m7".
//
// # The shape is frozen
//
// Fourteen bytes is a permanent public contract, not a current implementation.
// Namespace pressure resolves in data (a registered census) and never in width.
// Every value in this package that the wire can observe — the epoch, the
// alphabet's ASCII ordering, the field widths, the fixed 11-char payload — is
// pinned by a frozen vector in contract_test.go that the Elixir, Rust, C and
// TypeScript implementations assert independently. Those runtimes share no code
// with this one: the contract travels between languages as test vectors. Within
// Go it now travels as this package, and the vectors stay, because they are what
// proves the two forms still agree.
//
// # Ordering, stated honestly
//
// Byte-sorting branded ids reproduces mint order BETWEEN milliseconds: the
// timestamp is the high field and the fixed-width Base62 body compares
// lexicographically exactly as the snowflake compares numerically. That is what
// makes MinFor a usable cursor for time-range scans.
//
// Within a single millisecond the ordering is node-then-seq. So two ids minted
// in the same millisecond on DIFFERENT nodes do not sort by mint order. One
// minter's stream is always strictly ordered; a merge of several is ordered only
// to millisecond granularity. TestTsMajorOrdering states this as the contract.
//
// # Uniqueness, stated honestly
//
// A Generator is strictly monotonic under every clock regime. Bursts past
// 4096 ids/ms borrow into the timestamp rather than blocking, and a backward
// clock step keeps minting off the logical clock — no duplicates, no sleeping,
// no coordination.
//
// Across processes, uniqueness rests on the node field. DefaultNode derives it
// from FNV-32a over the hostname followed by the ASCII-decimal pid, masked to
// 10 bits — so two processes on one host almost always differ, with a residual
// collision of about 1 in 1024 per same-host process pair. That residual is
// load-independent and never zero: it is budgetable, not absent. A service whose
// ids must stay attributable to it should pin its node explicitly with
// NewGenerator or NewMinter rather than derive one.
//
// # Namespaces are yours
//
// This package ships no namespaces and no census. Which three-letter brands
// exist, what they mean, and which of them a given service may mint are policy,
// and policy belongs to the consumer. Encode and Parse enforce the SHAPE of a
// namespace (three bytes of A-Z) and nothing about its meaning, so "ZZZ" is a
// well-formed brand here and may be an unregistered one in your system.
//
// Plug your policy in with Gate:
//
//	var census = map[string]bool{"USR": true, "SES": true}
//
//	g := brd14.NewGenerator(brd14.DefaultNode())
//	m := brd14.NewMinter(g, func(ns string) error {
//		if !census[ns] {
//			return fmt.Errorf("refusing to mint %q: not in the census", ns)
//		}
//		return nil
//	})
//
//	id, err := m.Mint("USR")   // "USR0KHTOWnGLuC"
//	_, err = m.Mint("ZZZ")     // your error, in your words
//
// A nil Gate means no policy — every well-formed namespace is admitted. It does
// not mean no validation.
package brd14
