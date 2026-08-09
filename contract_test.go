package brd14

// The cross-language contract vectors (V-1..V-7) and the totality properties
// (T-1..T-4b) for the brd14 codec.
//
// Doctrine, from this package's own header: "the contract travels as test
// vectors, not as a shared object". The Go and Elixir implementations share no
// code — they share these literals. Every vector below is asserted by the
// Elixir suite too (citations per family), and the acceptance runs BOTH
// suites, so byte-equality is proven with zero Elixir bytes changed.
//
// The seeds are PINNED. These are deterministic property families, not a fuzz
// lane: a failure reproduces exactly, on any host, on any run.

import (
	"errors"
	"math/rand/v2"
	"slices"
	"strings"
	"testing"
)

const (
	// vecSnowUSR is the V-1/V-6 reference snowflake (branded_id.ex:119).
	vecSnowUSR = 274557032793636864
	// vecSnowParse is the V-2 reference snowflake (branded_id.ex:120).
	vecSnowParse = 320636799581945856
	// maxSnow is the largest encodable snowflake: the codec's domain is int64.
	maxSnow = uint64(1)<<63 - 1
)

// pinnedRand builds the deterministic source for one property family. Distinct
// streams keep one family's draws from shifting another's when a family grows.
func pinnedRand(stream uint64) *rand.Rand {
	return rand.New(rand.NewPCG(0x9E3779B97F4A7C15, stream))
}

// ── V-1..V-6: the cross-language byte-equal vectors ─────────────────────────

// TestVectorsCrossLanguage pins the literals the Elixir suite independently
// asserts (INV-XLANG-VECTOR, INV-WIRE-SHAPE).
func TestVectorsCrossLanguage(t *testing.T) {
	// V-1 — encode the reference snowflake, and Parse inverts it.
	const v1 = "USR0KHTOWnGLuC"
	got, err := Encode("USR", vecSnowUSR)
	if err != nil || got != v1 {
		t.Fatalf("V-1 Encode: got %q err=%v, want %q", got, err, v1)
	}
	if ns, snow, perr := Parse(v1); perr != nil || ns != "USR" || snow != vecSnowUSR {
		t.Fatalf("V-1 Parse inverse: ns=%q snow=%d err=%v", ns, snow, perr)
	}

	// V-2 — parse the second reference id.
	if ns, snow, perr := Parse("USR0NgWEfAEJfs"); perr != nil || ns != "USR" || snow != vecSnowParse {
		t.Fatalf("V-2: ns=%q snow=%d err=%v", ns, snow, perr)
	}

	// V-3 — the zero snowflake's payload is eleven '0's: the fixed-width law.
	// All eleven positions are written unconditionally, never trimmed; the
	// fixed width is half of why a byte-wise sort orders ids (V-7).
	zero, err := Encode("ABC", 0)
	if err != nil || zero != "ABC00000000000" {
		t.Fatalf("V-3: got %q err=%v, want ABC00000000000", zero, err)
	}
	if len(zero) != Len {
		t.Fatalf("V-3 width: len %d, want %d", len(zero), Len)
	}

	// V-4 — base62(2^63-1) is "AzL8n0Y58m7", byte-equal to the Elixir
	// @max_payload (base62.ex:17). The COMPUTED encoding, the package const,
	// and the literal are pinned to each other: a drifted const reds even
	// though it would still agree with itself.
	top, err := Encode("ABC", maxSnow)
	if err != nil {
		t.Fatalf("V-4 Encode(2^63-1): %v", err)
	}
	if top[3:] != "AzL8n0Y58m7" {
		t.Fatalf("V-4: base62(2^63-1) = %q, want AzL8n0Y58m7", top[3:])
	}
	if maxPayload != "AzL8n0Y58m7" {
		t.Fatalf("V-4: the maxPayload const = %q, want AzL8n0Y58m7", maxPayload)
	}

	// V-5 — the reject classes (branded_id.ex:121, base62.ex:11-12).
	for name, bad := range map[string]string{
		"payload above 2^63-1": "USRzzzzzzzzzzz",
		"lowercase namespace":  "usr0KHTOWnGLuC",
		"length below Len":     "USR0KHTOWnGLu",
		"length above Len":     "USR0KHTOWnGLuCC",
	} {
		if Valid(bad) {
			t.Errorf("V-5 %s: %q accepted, want rejected", name, bad)
		}
	}

	// V-6 — the trie-placement hash (branded_id.ex:14-15).
	if got := Hash32(vecSnowUSR); got != 234878118 {
		t.Fatalf("V-6 Hash32(%d) = %d, want 234878118", vecSnowUSR, got)
	}
}

// ── V-7: ordering, proven directly ──────────────────────────────────────────

// TestOrderingByteSortReproducesMintOrder is V-7 (INV-ORDER-LEX): the fabric's
// headline claim — branded ids are time-ordered, they "sort by creation" —
// asserted directly instead of inferred from the alphabet.
//
// Why this family is not redundant with the exact-byte pins: a full alphabet
// REVERSAL reds V-1/V-4, but a permutation that FIXES the ~17 characters those
// pins happen to use while permuting the other 45 round-trips perfectly, evades
// every exact-byte vector, and still destroys ordering. Only an ordering
// assertion catches that mutant class.
//
// NAMED GAP (awk-nodeid.md §5.1): the Elixir suite carries no ordering
// assertion. Its claim rests on the shared ASCII-ascending alphabet literal
// (base62.ex:15) plus fixed width — true by construction, untested there.
func TestOrderingByteSortReproducesMintOrder(t *testing.T) {
	// Snowflakes 0..61 put EVERY alphabet index in the low digit, so any
	// transposition of two alphabet positions reorders this set. That sweep is
	// load-bearing and was added after a probe: a sparse vector set (0, 1, 61,
	// 62, …) misses a permutation that swaps two indices the set never
	// exercises — the exact "pin-evading permutation" this family exists to
	// catch. The remaining entries add the carry boundaries, a populated
	// node+seq field, the maximum ts, and the maxPayload edge.
	mintOrder := make([]uint64, 0, 62+9)
	for i := uint64(0); i < 62; i++ {
		mintOrder = append(mintOrder, i)
	}
	mintOrder = append(mintOrder,
		62,         // the single-digit carry: "…0z" -> "…10"
		3843, 3844, // the double-digit carry: "…0zz" -> "…100"
		1<<22,                // ts = 1, node and seq zero
		1<<22|613<<seqBits|7, // ts = 1 with node+seq populated
		2<<22,                // ts = 2
		1234567<<22,
		(1<<41-1)<<22, // the maximum ts
		maxSnow,       // the maxPayload edge
	)
	for i := 1; i < len(mintOrder); i++ {
		if mintOrder[i] <= mintOrder[i-1] {
			t.Fatalf("the vector set is not strictly increasing at %d — V-7's premise is broken", i)
		}
	}

	encoded := make([]string, len(mintOrder))
	for i, snow := range mintOrder {
		id, err := Encode("SES", snow)
		if err != nil {
			t.Fatalf("encode %d: %v", snow, err)
		}
		encoded[i] = id
	}

	shuffled := slices.Clone(encoded)
	pinnedRand(1).Shuffle(len(shuffled), func(i, j int) {
		shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
	})
	slices.Sort(shuffled) // a plain byte-wise sort: no decoding, no comparator

	if !slices.Equal(shuffled, encoded) {
		t.Fatalf("V-7 byte-wise sort did not reproduce mint order:\n got %q\nwant %q", shuffled, encoded)
	}
}

// ── T-1: totality ───────────────────────────────────────────────────────────

// TestParseTotality is T-1 (INV-PARSE-TOTAL): every input yields a value or
// ErrInvalid — never a panic, never a foreign error, never a half-decoded
// result. The codec sits at every boundary an agent can reach, so its domain is
// "any byte string" and totality is a contract, not a courtesy.
func TestParseTotality(t *testing.T) {
	check := func(s string) {
		defer func() {
			if p := recover(); p != nil {
				t.Fatalf("T-1 panic on input %q (len %d): %v", s, len(s), p)
			}
		}()
		ns, snow, err := Parse(s)
		if err != nil {
			if !errors.Is(err, ErrInvalid) {
				t.Fatalf("T-1 %q: error %v is not ErrInvalid", s, err)
			}
			if ns != "" || snow != 0 {
				t.Fatalf("T-1 %q: refusal returned ns=%q snow=%d, want zero values", s, ns, snow)
			}
		}
		if Valid(s) != (err == nil) {
			t.Fatalf("T-1 %q: Valid disagrees with Parse (err=%v)", s, err)
		}
		d, derr := Decode(s)
		if (derr == nil) != (err == nil) || d != snow {
			t.Fatalf("T-1 %q: Decode (%d,%v) disagrees with Parse (%d,%v)", s, d, derr, snow, err)
		}
	}

	// The SHORT inputs are the sharpest. Parse guards on length BEFORE calling
	// upper3, which indexes s[0], s[1], s[2] unconditionally; Go's || is
	// short-circuiting, so the order of those two conditions is load-bearing.
	// Swap them and every input under 3 bytes panics. That is the defect class
	// T-1 exists to pin.
	for _, s := range []string{
		"", "A", "AB", "ABC", "USR",
		"USR0KHTOWnGLu", "USR0KHTOWnGLuC", "USR0KHTOWnGLuCX",
	} {
		check(s)
	}

	// Multi-byte and control bytes: the payload decoder indexes a [256]int8
	// table, so every possible byte value must land inside it.
	for _, s := range []string{
		"日本語のテスト文字列", "ÄÖÜ0KHTOWnGLuC", "\x00\x01\x02", strings.Repeat("\xff", Len),
	} {
		check(s)
	}

	// Arbitrary bytes across every length spanning Len.
	r := pinnedRand(2)
	for l := 0; l <= 20; l++ {
		for i := 0; i < 200; i++ {
			b := make([]byte, l)
			for j := range b {
				b[j] = byte(r.UintN(256))
			}
			check(string(b))
		}
	}
}

// ── T-2: round-trip over the whole domain ───────────────────────────────────

// TestRoundTripOverDomain is T-2: Parse(Encode(ns, snow)) == (ns, snow) for
// every valid namespace and every snowflake in [0, 2^63-1], driven from a
// pinned seed with the boundary set enumerated explicitly.
func TestRoundTripOverDomain(t *testing.T) {
	for _, snow := range []uint64{
		0, 1, 61, 62, 3843, 3844,
		1 << 22, 1<<41 - 1, (1<<41 - 1) << 22,
		maxSnow - 1, maxSnow,
	} {
		roundTripOnce(t, "USR", snow)
	}

	r := pinnedRand(3)
	for i := 0; i < 20000; i++ {
		roundTripOnce(t, randNS(r), r.Uint64()>>1) // >>1: uniform over [0, 2^63-1]
	}
}

func roundTripOnce(t *testing.T, ns string, snow uint64) {
	t.Helper()
	id, err := Encode(ns, snow)
	if err != nil {
		t.Fatalf("T-2 Encode(%q,%d): %v", ns, snow, err)
	}
	if len(id) != Len {
		t.Fatalf("T-2 Encode(%q,%d) = %q: len %d, want %d", ns, snow, id, len(id), Len)
	}
	gotNS, gotSnow, perr := Parse(id)
	if perr != nil || gotNS != ns || gotSnow != snow {
		t.Fatalf("T-2 round-trip %q/%d via %q: got ns=%q snow=%d err=%v", ns, snow, id, gotNS, gotSnow, perr)
	}
}

func randNS(r *rand.Rand) string {
	var b [3]byte
	for i := range b {
		b[i] = byte('A' + r.UintN(26))
	}
	return string(b[:])
}

// ── T-3: the domain guards ──────────────────────────────────────────────────

// TestDomainGuards is T-3: every input outside the codec's domain is REFUSED,
// on both directions of the boundary.
func TestDomainGuards(t *testing.T) {
	// Encode refuses a snowflake outside int64.
	for _, snow := range []uint64{1 << 63, 1<<63 + 1, ^uint64(0)} {
		if id, err := Encode("USR", snow); err == nil {
			t.Errorf("T-3 Encode(snow=%d) = %q, want ErrInvalid", snow, id)
		}
	}

	// Encode refuses every namespace outside the 3 x [A-Z] branded grammar.
	// This is the BRANDED grammar, whose sole authority in this tree is upper3;
	// it is deliberately NOT the echapp mirror-prefix grammar (awkapp.ValidPrefix,
	// non-empty [A-Za-z0-9_]), which is a different surface with its own single
	// authority. A prefix like "echdos" is legal there and illegal here, by design.
	for _, ns := range []string{"", "U", "US", "USRR", "usr", "UsR", "US1", "US ", "US-", "ÄÖÜ"} {
		if id, err := Encode(ns, 1); err == nil {
			t.Errorf("T-3 Encode(ns=%q) = %q, want ErrInvalid", ns, id)
		}
	}

	// Parse's range guard is LEXICOGRAPHIC, and T-4 proves lex == numeric, so
	// the guard is EXACT: the maxPayload id itself parses to 2^63-1, and its
	// lexicographic successor (which is numerically 2^63) is refused.
	if _, snow, err := Parse("USR" + maxPayload); err != nil || snow != maxSnow {
		t.Errorf("T-3 boundary: Parse(maxPayload) = %d/%v, want %d/nil", snow, err, maxSnow)
	}
	if _, _, err := Parse("USRAzL8n0Y58m8"); err == nil {
		t.Errorf("T-3 boundary: Parse accepted the successor of maxPayload (numerically 2^63)")
	}

	// Parse refuses a namespace outside the grammar, a byte outside the
	// alphabet, and every length other than Len.
	for name, bad := range map[string]string{
		"lowercase ns":       "usr00000000000",
		"digit in ns":        "US100000000000",
		"payload above max":  "USRzzzzzzzzzzz",
		"non-alphabet byte":  "USR0KHTOWnGLu!",
		"non-alphabet space": "USR0KHTOWnGLu ",
		"length 13":          "USR0000000000",
		"length 15":          "USR000000000000",
		"length 0":           "",
	} {
		if _, _, err := Parse(bad); err == nil {
			t.Errorf("T-3 %s: Parse(%q) accepted, want ErrInvalid", name, bad)
		}
	}
}

// ── T-4 / T-4b: the ordering laws ───────────────────────────────────────────

// TestPayloadOrderLexEqualsNumeric is T-4: payload lexicographic order is
// IDENTICAL to numeric order. This is what makes a byte-wise sort of ids a
// chronological sort (V-7) and what makes Parse's lexicographic range guard an
// exact numeric guard (T-3).
func TestPayloadOrderLexEqualsNumeric(t *testing.T) {
	// The carry boundary, spot-verified at spec time: enc(61) < enc(62), where
	// the payload rolls "…0z" -> "…10" and the lexicographic comparison must
	// follow the carry rather than the digit.
	if a, b := MustEncode("SES", 61)[3:], MustEncode("SES", 62)[3:]; !(a < b) {
		t.Fatalf("T-4 carry boundary: enc(61)=%q not < enc(62)=%q", a, b)
	}

	r := pinnedRand(4)
	for i := 0; i < 20000; i++ {
		x, y := r.Uint64()>>1, r.Uint64()>>1
		ex, ey := MustEncode("SES", x)[3:], MustEncode("SES", y)[3:]
		switch {
		case x < y && !(ex < ey):
			t.Fatalf("T-4 %d < %d but %q not < %q", x, y, ex, ey)
		case x > y && !(ex > ey):
			t.Fatalf("T-4 %d > %d but %q not > %q", x, y, ex, ey)
		case x == y && ex != ey:
			t.Fatalf("T-4 %d == %d but %q != %q", x, y, ex, ey)
		}
	}
}

// TestTsMajorOrdering is T-4b, the SEAM-2 contract stated TRUTHFULLY.
//
// The consumer seat asked that "node bits never participate in sort order" be
// pinned. As stated that is FALSE of this layout: within ONE millisecond the
// numeric order ties break on the node field. The TRUE contract is that
// ordering is ts-MAJOR — for ts1 < ts2, id1 < id2 numerically AND payload1 <
// payload2 lexicographically REGARDLESS of node and seq (high-field dominance).
//
// The consequence that matters for this ship: a node-derivation change can
// never reorder ids across distinct milliseconds. It only re-permutes the
// within-millisecond tie-break values, which were node-arbitrary before the fix
// and remain node-arbitrary after it.
func TestTsMajorOrdering(t *testing.T) {
	const maxTs = 1<<41 - 1
	r := pinnedRand(5)
	for i := 0; i < 20000; i++ {
		ts1 := r.Uint64N(maxTs)
		ts2 := ts1 + 1 + r.Uint64N(maxTs-ts1)

		// The tightest case: the EARLIER id carries the maximum node and seq,
		// the LATER id carries the minimum. If the fields could ever outrank
		// the timestamp, this pair is where it would show.
		lo := ts1<<22 | nodeMask<<seqBits | seqMask
		hi := ts2 << 22
		assertOrdered(t, "extremal", lo, hi)

		// And with arbitrary node/seq on both sides.
		lo = ts1<<22 | r.Uint64N(nodeMask+1)<<seqBits | r.Uint64N(seqMask+1)
		hi = ts2<<22 | r.Uint64N(nodeMask+1)<<seqBits | r.Uint64N(seqMask+1)
		assertOrdered(t, "arbitrary", lo, hi)
	}
}

func assertOrdered(t *testing.T, label string, lo, hi uint64) {
	t.Helper()
	if lo >= hi {
		t.Fatalf("T-4b %s: numeric order broken — %d >= %d despite an earlier ts", label, lo, hi)
	}
	elo, ehi := MustEncode("SES", lo)[3:], MustEncode("SES", hi)[3:]
	if !(elo < ehi) {
		t.Fatalf("T-4b %s: payload order broken — %q not < %q (snowflakes %d, %d)", label, elo, ehi, lo, hi)
	}
}
