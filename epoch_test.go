package brd14

// The epoch, pinned ABSOLUTELY.
//
// This file exists because of a measured gap, not a hypothetical one. Changing
// EpochMs by a single millisecond leaves every other test in this package GREEN
// — all 26 of them, including TestEpochBoundaries, whose name promises exactly
// this coverage. It does not have it: every assertion there is written relative
// to EpochMs itself (UnixMs(0) == EpochMs, MinFor(time.UnixMilli(EpochMs)) == 0),
// so it compares the constant against itself and is satisfied by ANY value. What
// it really pins is the field partition — that node and seq never leak into the
// extracted instant — which is worth having and is not this.
//
// The gap matters more than a missing test usually would. The epoch is the only
// constant that decides what a timestamp MEANS, and it is the one that has
// actually drifted in practice: sibling minters in the wild carry
// 1_700_000_000_000, and ids they produce decode to an instant four months
// wrong under a conforming reader — silently, since every id still parses, still
// sorts, and still round-trips. A round-trip cannot see it. Only an absolute
// literal can.
//
// The literals below are not derived from EpochMs. They are the instants the
// canonical Elixir reference documents for the same two frozen snowflakes that
// V-1 and V-2 already pin, so this file and the cross-language vectors agree by
// construction, and a change to EpochMs breaks the agreement rather than
// travelling with it.

import (
	"testing"
	"time"
)

func TestEpochIsPinnedAbsolutely(t *testing.T) {
	// The epoch itself: 2024-01-01T00:00:00Z, stated as a literal rather than
	// as EpochMs, which is the whole point of the file.
	const epochLiteral = 1_704_067_200_000
	if EpochMs != epochLiteral {
		t.Fatalf("EpochMs = %d, want %d (2024-01-01T00:00:00Z) — the contract epoch is FROZEN; "+
			"every other runtime decodes against this exact value", EpochMs, epochLiteral)
	}
	if got := time.UnixMilli(EpochMs).UTC().Format(time.RFC3339); got != "2024-01-01T00:00:00Z" {
		t.Fatalf("the epoch instant is %s, want 2024-01-01T00:00:00Z", got)
	}
}

// TestVectorInstantsAreAbsolute decodes the two frozen contract snowflakes to
// wall-clock instants and compares them to literals. These are the same
// snowflakes V-1 and V-2 pin as branded strings; here they pin the TIME those
// strings claim, which the string vectors alone say nothing about.
func TestVectorInstantsAreAbsolute(t *testing.T) {
	cases := []struct {
		name string
		id   string
		snow uint64
		ms   int64
		utc  string
	}{
		// V-1's snowflake, its instant.
		{"V-1", "USR0KHTOWnGLuC", 274557032793636864, 1769526697641, "2026-01-27T15:11:37.641Z"},
		// V-2's snowflake, its instant — the value the Elixir reference records.
		{"V-2", "USR0NgWEfAEJfs", 320636799581945856, 1780512970164, "2026-06-03T18:56:10.164Z"},
	}

	for _, c := range cases {
		// The branded string, the snowflake and the instant must all agree —
		// the three-way tie is what makes a single-constant drift detectable.
		_, snow, err := Parse(c.id)
		if err != nil || snow != c.snow {
			t.Fatalf("%s: Parse(%q) = %d, %v; want %d", c.name, c.id, snow, err, c.snow)
		}
		if got := UnixMs(c.snow); got != c.ms {
			t.Fatalf("%s: UnixMs(%d) = %d, want %d — EpochMs has drifted by %d ms",
				c.name, c.snow, got, c.ms, got-c.ms)
		}
		if got := Time(c.snow).UTC().Format("2006-01-02T15:04:05.000Z"); got != c.utc {
			t.Fatalf("%s: Time(%d) = %s, want %s", c.name, c.snow, got, c.utc)
		}
	}
}

// TestMinForIsAbsolute pins the scan cursor against a wall-clock instant rather
// than against the epoch constant. MinFor is how a caller turns "everything
// since T" into a range bound, so an epoch drift here silently shifts every
// time-range query by the same amount without any query failing.
func TestMinForIsAbsolute(t *testing.T) {
	// 2026-01-27T15:11:37.641Z — V-1's instant.
	at := time.UnixMilli(1769526697641)
	const wantMin = uint64(1769526697641-1_704_067_200_000) << 22

	if got := MinFor(at); got != wantMin {
		t.Fatalf("MinFor(%s) = %d, want %d", at.UTC().Format(time.RFC3339Nano), got, wantMin)
	}
	// The bound is half-open and tight: V-1's own snowflake sits at or above it,
	// and the millisecond before it does not.
	if 274557032793636864 < wantMin {
		t.Fatal("MinFor excluded a snowflake minted at exactly that instant")
	}
	if MinFor(at.Add(-time.Millisecond)) >= wantMin {
		t.Fatal("MinFor is not strictly increasing across a millisecond")
	}
}
