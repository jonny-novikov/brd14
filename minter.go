// minter.go: the consumer-side namespace plug.
//
// The codec knows what a namespace LOOKS like (three bytes of A-Z) and nothing
// about what any particular one MEANS. Meaning is policy, policy differs per
// consumer — a closed brand census, a status-keyed registry mirrored from an
// upstream authority, or deliberately none at all — and none of those belong in
// a package every consumer shares. Minter is the seam between the two.

package brd14

import "errors"

// ErrRefused is what DenyAll returns. It is deliberately NOT ErrInvalid: a
// policy refusal and a malformed id are different facts, and a consumer that
// conflates them cannot tell "this brand is not yours to mint" from "this is not
// a branded id at all". A real policy should return its own error with its own
// detail rather than reuse this one.
var ErrRefused = errors.New("brd14: namespace refused by policy")

// Gate is a consumer's namespace policy: it reports whether ns may be minted.
//
// A nil error admits the mint. Any non-nil error refuses it and is returned to
// the caller UNCHANGED — the gate's own error, neither wrapped nor rephrased —
// so a refusal arrives in the consumer's own words, carrying whatever detail the
// policy knows and this package does not: which registry the brand is missing
// from, what status it holds, who owns it.
type Gate func(ns string) error

// AllowAll is the explicit spelling of the nil gate: every namespace passes
// policy, and only the codec's shape check applies.
func AllowAll(string) error { return nil }

// DenyAll refuses every namespace. Useful as the initial value in a consumer
// that wires its real policy later, so a half-built minter refuses rather than
// admits.
func DenyAll(ns string) error { return ErrRefused }

// Minter is a Generator plus one policy decision.
//
// It WRAPS its Generator rather than embedding it, deliberately: embedding would
// promote Next and NextBranded onto *Minter, so m.NextBranded("ZZZ") would
// compile and mint straight past the gate. Reaching the ungated path has to be
// written out — m.Generator().NextBranded(ns) — so it is visible in review and
// greppable in a codebase.
//
// The zero value is not usable; construct one with NewMinter.
type Minter struct {
	g    *Generator
	gate Gate
}

// NewMinter returns a Minter over g, governed by gate.
//
// It takes a *Generator rather than a node id so a consumer that already owns a
// generator — because it also mints bare snowflakes, or because its existing
// mint helper is written against one — can gate that generator instead of
// running a second, independent one beside it.
//
//	m := brd14.NewMinter(brd14.NewGenerator(2), gate)          // a pinned node
//	m := brd14.NewMinter(brd14.NewGenerator(brd14.DefaultNode()), nil)
//
// A NIL gate admits every well-formed namespace. That is "no policy", never "no
// validation": the codec's three-bytes-of-A-Z check still applies, so a nil gate
// accepts "ZZZ" and still refuses "zz1". Nil is the useful default — it
// reproduces bare NextBranded exactly, which is what makes adopting a Minter
// behaviour-preserving — but it is also an OPEN gate, so a Gate variable that is
// accidentally nil mints anything. Write AllowAll when the openness is intended
// and DenyAll when it is not yet decided.
//
// NewMinter panics on a nil Generator: a Minter that cannot mint is a
// construction fault, and failing here beats a nil dereference at the first
// mint, arbitrarily later and far from the cause.
func NewMinter(g *Generator, gate Gate) *Minter {
	if g == nil {
		panic("brd14: NewMinter called with a nil *Generator")
	}
	return &Minter{g: g, gate: gate}
}

// Mint gates ns, then brands the next snowflake.
//
// Precedence — the gate runs FIRST, before the codec's shape check:
//
//  1. gate(ns) returns non-nil -> ("", that error), unchanged.
//  2. otherwise                -> Encode(ns, g.Next()), so a namespace outside
//     the branded grammar yields ("", ErrInvalid).
//
// Gate-first is not arbitrary. The policy error is the more specific and more
// actionable of the two, and the gate must see the RAW ns the caller passed so
// its message can quote it verbatim. Shape-first would turn a census refusal of
// "log" into a bare ErrInvalid and destroy the diagnostic the census exists to
// produce.
func (m *Minter) Mint(ns string) (string, error) {
	id, _, err := m.MintSnowflake(ns)
	return id, err
}

// MintSnowflake mints under ns and returns the branded id together with the
// snowflake behind it, for callers that report the decoded fields — the mint
// instant, the node, the sequence — and would otherwise have to parse back an id
// they just produced.
func (m *Minter) MintSnowflake(ns string) (id string, snow uint64, err error) {
	if m.gate != nil {
		if err := m.gate(ns); err != nil {
			return "", 0, err
		}
	}
	snow = m.g.Next()
	id, err = Encode(ns, snow)
	if err != nil {
		return "", 0, err
	}
	return id, snow, nil
}

// MustMint mints under ns and panics on refusal. For a call site whose namespace
// is a compile-time constant already known to the policy, where a refusal is a
// programming fault rather than a runtime condition.
func (m *Minter) MustMint(ns string) string {
	id, err := m.Mint(ns)
	if err != nil {
		panic(err)
	}
	return id
}

// Generator returns the underlying generator — the UNGATED path, and the only
// way to reach Next for a bare snowflake. Named rather than promoted, so every
// bypass reads as one.
func (m *Minter) Generator() *Generator { return m.g }
