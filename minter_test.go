package brd14

// The Gate/Minter plug — the one surface in this package that is NOT frozen by
// the cross-language vectors, and therefore the one that needs its own tests.
//
// Two of them are load-bearing beyond ordinary coverage:
//
//   - TestGateErrorReturnedVerbatim pins the promise that a consumer's refusal
//     reaches its caller unmodified. It reproduces the exact format string a
//     real downstream census uses, byte for byte, so that adding a `%w` wrapper
//     to Mint — which would look like a harmless improvement — reds here.
//   - TestGatePrecedence pins gate-before-shape. Moving the codec check first
//     is invisible to every other test in this file (both orderings refuse), and
//     it would silently convert a consumer's diagnostic into a bare ErrInvalid.

import (
	"errors"
	"fmt"
	"strings"
	"testing"
)

// censusGate reproduces the shape of a real downstream namespace policy: a
// status-keyed registry that refuses with a message naming both the code and
// why it was refused.
func censusGate(status map[string]string) Gate {
	return func(ns string) error {
		if status[ns] == "active" {
			return nil
		}
		st := status[ns]
		if st == "" {
			st = "unregistered"
		}
		return fmt.Errorf("census: refusing to mint %q — not census-active (status: %s)", ns, st)
	}
}

var testCensus = map[string]string{"USR": "active", "SES": "active", "LOG": "reserved"}

// ── the nil gate: no policy, still validated ────────────────────────────────

func TestNilGateAdmitsAnyWellFormedNamespace(t *testing.T) {
	m := NewMinter(NewGenerator(7), nil)

	// ZZZ is well-formed and (in any real system) unregistered. A nil gate is
	// "no policy": it must admit it. This is the behaviour a consumer with no
	// census relies on, and the reason nil does not mean deny.
	id, err := m.Mint("ZZZ")
	if err != nil {
		t.Fatalf("nil gate refused a well-formed ns: %v", err)
	}
	if !Valid(id) {
		t.Fatalf("nil gate produced an invalid id %q", id)
	}
	ns, snow, err := Parse(id)
	if err != nil || ns != "ZZZ" {
		t.Fatalf("Parse(%q) = %q, %d, %v; want ns ZZZ", id, ns, snow, err)
	}
	if got := NodeOf(snow); got != 7 {
		t.Fatalf("node = %d, want 7 — the Minter did not use the Generator it was given", got)
	}
}

func TestNilGateStillEnforcesShape(t *testing.T) {
	m := NewMinter(NewGenerator(1), nil)
	for _, ns := range []string{"zz1", "us", "USRX", "", "U R"} {
		id, err := m.Mint(ns)
		if !errors.Is(err, ErrInvalid) {
			t.Fatalf("Mint(%q) err = %v, want ErrInvalid — nil gate must not disable the codec check", ns, err)
		}
		if id != "" {
			t.Fatalf("Mint(%q) returned id %q on refusal, want empty", ns, id)
		}
	}
}

func TestAllowAllMatchesNilGate(t *testing.T) {
	nilGate := NewMinter(NewGenerator(3), nil)
	allow := NewMinter(NewGenerator(3), AllowAll)

	for _, ns := range []string{"USR", "ZZZ"} {
		a, errA := nilGate.Mint(ns)
		b, errB := allow.Mint(ns)
		if errA != nil || errB != nil {
			t.Fatalf("Mint(%q): nil gate err=%v, AllowAll err=%v; want both nil", ns, errA, errB)
		}
		if a[:3] != ns || b[:3] != ns {
			t.Fatalf("Mint(%q) branded %q / %q", ns, a[:3], b[:3])
		}
	}
	if _, err := nilGate.Mint("zz1"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("nil gate on bad shape: %v", err)
	}
	if _, err := allow.Mint("zz1"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("AllowAll on bad shape: %v", err)
	}
}

func TestDenyAllRefusesEverything(t *testing.T) {
	m := NewMinter(NewGenerator(1), DenyAll)
	for _, ns := range []string{"USR", "ZZZ", "zz1"} {
		id, err := m.Mint(ns)
		if !errors.Is(err, ErrRefused) {
			t.Fatalf("DenyAll Mint(%q) err = %v, want ErrRefused", ns, err)
		}
		if id != "" {
			t.Fatalf("DenyAll Mint(%q) returned id %q, want empty", ns, id)
		}
	}
	// A policy refusal is not a malformed id, and must not masquerade as one.
	if _, err := m.Mint("USR"); errors.Is(err, ErrInvalid) {
		t.Fatal("ErrRefused satisfies errors.Is(err, ErrInvalid) — a policy refusal and a " +
			"malformed id have been conflated")
	}
}

// ── the two load-bearing ones ───────────────────────────────────────────────

// TestGateErrorReturnedVerbatim is the test that makes "returned UNCHANGED" a
// promise rather than a doc comment. The want string is the real one, spelled
// out — em-dash included — so any wrapping, prefixing or reformatting inside
// Mint reds here with a readable diff.
func TestGateErrorReturnedVerbatim(t *testing.T) {
	m := NewMinter(NewGenerator(1), censusGate(testCensus))

	const want = `census: refusing to mint "LOG" — not census-active (status: reserved)`
	_, err := m.Mint("LOG")
	if err == nil {
		t.Fatal("Mint(LOG) succeeded; a reserved code must be refused")
	}
	if got := err.Error(); got != want {
		t.Fatalf("gate error was modified in transit:\n got: %s\nwant: %s", got, want)
	}

	const wantUnreg = `census: refusing to mint "ZZZ" — not census-active (status: unregistered)`
	if _, err := m.Mint("ZZZ"); err == nil || err.Error() != wantUnreg {
		t.Fatalf("unregistered code: got %v, want %s", err, wantUnreg)
	}
}

// TestGatePrecedence pins the gate BEFORE the codec's shape check.
//
// "log" is both off-census and malformed (lowercase), so it is refused under
// either ordering — which is exactly why this needs its own test: every other
// assertion in this file passes with the checks in either order. Only the
// identity of the error tells them apart, and getting it wrong destroys the
// diagnostic a census exists to produce.
func TestGatePrecedence(t *testing.T) {
	m := NewMinter(NewGenerator(1), censusGate(testCensus))

	_, err := m.Mint("log")
	if err == nil {
		t.Fatal("Mint(log) succeeded")
	}
	if errors.Is(err, ErrInvalid) {
		t.Fatalf("shape check ran BEFORE the gate: got %v, want the census refusal", err)
	}
	if !strings.HasPrefix(err.Error(), "census: refusing to mint") {
		t.Fatalf("got %q, want the gate's own message", err)
	}

	// And the converse: once the gate admits, the codec still refuses a
	// malformed namespace on its own terms.
	open := NewMinter(NewGenerator(1), AllowAll)
	if _, err := open.Mint("lo"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("gate admitted, codec should refuse: got %v, want ErrInvalid", err)
	}
}

// ── MintSnowflake, MustMint, and the ungated path ───────────────────────────

func TestMintSnowflakeAgreesWithTheID(t *testing.T) {
	m := NewMinter(NewGenerator(613), censusGate(testCensus))

	id, snow, err := m.MintSnowflake("USR")
	if err != nil {
		t.Fatalf("MintSnowflake: %v", err)
	}
	ns, parsed, err := Parse(id)
	if err != nil {
		t.Fatalf("Parse(%q): %v", id, err)
	}
	if ns != "USR" || parsed != snow {
		// A returned snowflake that does not match the id is the one defect a
		// caller cannot detect, because it stops parsing once it has both.
		t.Fatalf("MintSnowflake returned (%q, %d) but the id decodes to (%q, %d)", id, snow, ns, parsed)
	}
	if NodeOf(snow) != 613 {
		t.Fatalf("node = %d, want 613", NodeOf(snow))
	}

	if _, _, err := m.MintSnowflake("LOG"); err == nil {
		t.Fatal("MintSnowflake bypassed the gate")
	}
}

func TestMintSnowflakeIsMonotonic(t *testing.T) {
	m := NewMinter(NewGenerator(9), nil)
	prev := uint64(0)
	prevID := ""
	for i := 0; i < 5000; i++ {
		id, snow, err := m.MintSnowflake("SES")
		if err != nil {
			t.Fatalf("mint %d: %v", i, err)
		}
		if snow <= prev {
			t.Fatalf("mint %d: snowflake %d not greater than %d", i, snow, prev)
		}
		if prevID != "" && id <= prevID {
			t.Fatalf("mint %d: id %q does not byte-sort after %q", i, id, prevID)
		}
		prev, prevID = snow, id
	}
}

func TestMustMint(t *testing.T) {
	m := NewMinter(NewGenerator(1), censusGate(testCensus))

	if id := m.MustMint("USR"); !Valid(id) {
		t.Fatalf("MustMint produced %q", id)
	}

	defer func() {
		r := recover()
		if r == nil {
			t.Fatal("MustMint did not panic on a refused namespace")
		}
		err, ok := r.(error)
		if !ok || !strings.HasPrefix(err.Error(), "census: refusing to mint") {
			t.Fatalf("panicked with %v; want the gate's own error", r)
		}
	}()
	m.MustMint("LOG")
}

// TestGeneratorIsTheUngatedPath proves the bypass exists, is reachable only by
// name, and is genuinely separate from the gated one — which is the whole
// argument for wrapping the Generator instead of embedding it. Embedding would
// promote NextBranded onto *Minter, and m.NextBranded("LOG") would compile and
// mint past a policy that had just refused it.
func TestGeneratorIsTheUngatedPath(t *testing.T) {
	g := NewGenerator(11)
	m := NewMinter(g, DenyAll)

	if m.Generator() != g {
		t.Fatal("Generator() did not return the generator NewMinter was given")
	}
	if _, err := m.Mint("USR"); err == nil {
		t.Fatal("the gate did not refuse")
	}
	id, err := m.Generator().NextBranded("USR")
	if err != nil || !Valid(id) {
		t.Fatalf("the ungated path should still mint: %q, %v", id, err)
	}
	if _, snow, _ := Parse(id); NodeOf(snow) != 11 {
		t.Fatal("the ungated path used a different generator")
	}
}

func TestNewMinterPanicsOnNilGenerator(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("NewMinter(nil, ...) did not panic; a Minter that cannot mint " +
				"should fail at construction, not at the first mint")
		}
	}()
	NewMinter(nil, AllowAll)
}
