package brd14

import "testing"

const refSnow = 274557032793636864

// TestContractVectors re-asserts the canonical brd14 vectors so this vendored
// copy can never silently drift from the reference codec.
func TestContractVectors(t *testing.T) {
	if id := MustEncode("USR", refSnow); id != "USR0KHTOWnGLuC" {
		t.Fatalf("USR vector: got %q want USR0KHTOWnGLuC", id)
	}
	ns, snow, err := Parse("USR0NgWEfAEJfs")
	if err != nil || ns != "USR" || snow != 320636799581945856 {
		t.Fatalf("parse vector: ns=%q snow=%d err=%v", ns, snow, err)
	}
	if got := Hash32(refSnow); got != 234878118 {
		t.Fatalf("Hash32 vector: got %d want 234878118", got)
	}
}

func TestRejectsInvalid(t *testing.T) {
	for _, bad := range []string{
		"USRzzzzzzzzzzz", // payload beyond 2^63-1
		"usr0KHTOWnGLuC", // lowercase namespace
		"USR0KHTOWnGLu",  // short
		"USR0KHTOWnGLu!", // bad charset
	} {
		if Valid(bad) {
			t.Errorf("expected %q to be rejected", bad)
		}
	}
}

// TestMintMonotonicAndBranded proves the minter yields valid, strictly
// increasing branded ids carrying the requested namespace and node.
func TestMintMonotonicAndBranded(t *testing.T) {
	g := NewGenerator(7)
	var prev uint64
	for i := 0; i < 5000; i++ {
		id, err := g.NextBranded("SES")
		if err != nil {
			t.Fatalf("mint: %v", err)
		}
		if !Valid(id) {
			t.Fatalf("minted id %q is not valid", id)
		}
		ns, snow, err := Parse(id)
		if err != nil || ns != "SES" {
			t.Fatalf("parse %q: ns=%q err=%v", id, ns, err)
		}
		if snow <= prev {
			t.Fatalf("snowflake not strictly increasing: %d <= %d", snow, prev)
		}
		if NodeOf(snow) != 7 {
			t.Fatalf("node field: got %d want 7", NodeOf(snow))
		}
		prev = snow
	}
}
