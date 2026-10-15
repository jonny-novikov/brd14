package brd14

// The allocation contract, asserted rather than claimed.
//
// docs/architecture.md promises the Go reference allocates NOTHING on its hot
// path — the Append*, Parse* and Valid* families, Hash32, Next and the field
// readers — and exactly one string where a string is the product (Encode,
// NextBranded). A promise like that decays silently: one innocent fmt.Errorf in
// a refusal path, one interface conversion, one escaping buffer, and every
// caller's GC budget changes with no test going red. So each entry point below
// is measured with testing.AllocsPerRun, on its success path AND on the refusal
// path of every error class it can report — the refusals are where a "helpful"
// wrapped error would sneak in, and where a hostile peer can drive a server
// as often as it likes.
//
// Every case also checks its call's error against the expected one, so a
// zero-allocation result can never come from a call that quietly took the
// refusal path instead of the one being measured.

import (
	"errors"
	"testing"
	"time"
)

// Inputs live in variables, not constants, so the compiler cannot fold a call
// into its answer and leave nothing to measure.
var (
	allocNS      = "USR"
	allocSnow    = uint64(274557032793636864)
	allocID      = "USR0KHTOWnGLuC"
	allocIDb     = []byte("USR0KHTOWnGLuC")
	allocAt      = time.UnixMilli(1769526697641)
	allocHost    = "brd14-prod-01"
	allocBadNS   = "usr"
	allocBigSnow = uint64(1) << 63
	// allocVirtualNow is the virtual clock of the alloc cases: the V-1 instant.
	allocVirtualNow = int64(EpochMs + 65_459_497_641)

	// One decode refusal per class, each a single-fault input.
	allocRefusals = []struct {
		class string
		id    string
		err   error
	}{
		{"LENGTH", "USR0KHTOWnGLu", ErrLength},
		{"NAMESPACE", "usr0KHTOWnGLuC", ErrNamespace},
		{"CHARSET", "USR0KHTOWnGLu!", ErrCharset},
		{"RANGE", "USRzzzzzzzzzzz", ErrRange},
	}
)

// The sinks every measured result is stored into — here and in bench_test.go —
// so no call is dead code the compiler may delete.
var (
	sinkStr   string
	sinkU64   uint64
	sinkU32   uint32
	sinkI64   int64
	sinkBool  bool
	sinkBytes []byte
	sinkNS    [3]byte
	sinkTime  time.Time
)

type allocCase struct {
	name string
	want float64      // allocations per call
	f    func() error // the call; it stores its result in a sink and returns its error
	err  error        // the error f must return: nil, ErrInvalid, or a typed cause
}

// validErr lets a bool-returning call report through allocCase.f.
func validErr(ok bool) error {
	if ok {
		return nil
	}
	return ErrInvalid
}

func allocCases() []allocCase {
	g := NewGenerator(7)
	vg := NewGeneratorWithClock(8, func() int64 { return allocVirtualNow })
	m := NewMinter(g, AllowAll)
	buf := make([]byte, 0, 64) // cap-sufficient: AppendEncode must not grow it

	cs := []allocCase{
		// The zero-allocation family, success paths.
		{"AppendEncode", 0, func() (err error) { sinkBytes, err = AppendEncode(buf[:0], allocNS, allocSnow); return }, nil},
		{"Parse", 0, func() (err error) { sinkStr, sinkU64, err = Parse(allocID); return }, nil},
		{"ParseBytes", 0, func() (err error) { sinkNS, sinkU64, err = ParseBytes(allocIDb); return }, nil},
		{"Decode", 0, func() (err error) { sinkU64, err = Decode(allocID); return }, nil},
		{"DecodeBytes", 0, func() (err error) { sinkU64, err = DecodeBytes(allocIDb); return }, nil},
		{"Valid", 0, func() error { sinkBool = Valid(allocID); return validErr(sinkBool) }, nil},
		{"ValidBytes", 0, func() error { sinkBool = ValidBytes(allocIDb); return validErr(sinkBool) }, nil},
		{"Hash32", 0, func() error { sinkU32 = Hash32(allocSnow); return nil }, nil},
		{"UnixMs", 0, func() error { sinkI64 = UnixMs(allocSnow); return nil }, nil},
		{"Time", 0, func() error { sinkTime = Time(allocSnow); return nil }, nil},
		{"MinFor", 0, func() error { sinkU64 = MinFor(allocAt); return nil }, nil},
		{"NodeOf", 0, func() error { sinkU64 = NodeOf(allocSnow); return nil }, nil},
		{"SeqOf", 0, func() error { sinkU64 = SeqOf(allocSnow); return nil }, nil},
		{"NodeFrom", 0, func() error { sinkU64 = NodeFrom(allocHost, 2147483647); return nil }, nil},
		{"Next", 0, func() error { sinkU64 = g.Next(); return nil }, nil},
		{"AppendNextBranded", 0, func() (err error) { sinkBytes, err = g.AppendNextBranded(buf[:0], allocNS); return }, nil},
		{"Next/virtual-clock", 0, func() error { sinkU64 = vg.Next(); return nil }, nil},
		{"Observe", 0, func() (err error) { sinkBool, err = vg.Observe(allocSnow, 1<<40); return }, nil},
		{"Observe/refused-ahead", 0, func() (err error) { sinkBool, err = vg.Observe(allocSnow, -1<<40); return }, nil},
		{"Observe/RANGE", 0, func() (err error) { sinkBool, err = vg.Observe(allocBigSnow, 1<<40); return }, ErrRange},
		{"VirtualUnixMs", 0, func() error { sinkI64 = vg.VirtualUnixMs(); return nil }, nil},

		// Encode's two refusals, through every encode entry point.
		{"AppendEncode/NAMESPACE", 0, func() (err error) { sinkBytes, err = AppendEncode(buf[:0], allocBadNS, allocSnow); return }, ErrNamespace},
		{"AppendEncode/RANGE", 0, func() (err error) { sinkBytes, err = AppendEncode(buf[:0], allocNS, allocBigSnow); return }, ErrRange},
		{"Encode/NAMESPACE", 0, func() (err error) { sinkStr, err = Encode(allocBadNS, allocSnow); return }, ErrNamespace},
		{"Encode/RANGE", 0, func() (err error) { sinkStr, err = Encode(allocNS, allocBigSnow); return }, ErrRange},
		{"AppendNextBranded/NAMESPACE", 0, func() (err error) { sinkBytes, err = g.AppendNextBranded(buf[:0], allocBadNS); return }, ErrNamespace},
		{"NextBranded/NAMESPACE", 0, func() (err error) { sinkStr, err = g.NextBranded(allocBadNS); return }, ErrNamespace},

		// Exactly one allocation where a string is the product: the string.
		{"Encode", 1, func() (err error) { sinkStr, err = Encode(allocNS, allocSnow); return }, nil},
		{"NextBranded", 1, func() (err error) { sinkStr, err = g.NextBranded(allocNS); return }, nil},
		{"Minter.Mint", 1, func() (err error) { sinkStr, err = m.Mint(allocNS); return }, nil},
		// A nil dst costs append's growth and nothing else.
		{"AppendEncode/nil-dst", 1, func() (err error) { sinkBytes, err = AppendEncode(nil, allocNS, allocSnow); return }, nil},
	}

	// Every decode refusal class, through every decode entry point.
	for _, r := range allocRefusals {
		id, idb, cause := r.id, []byte(r.id), r.err
		cs = append(cs,
			allocCase{"Parse/" + r.class, 0, func() (err error) { sinkStr, sinkU64, err = Parse(id); return }, cause},
			allocCase{"ParseBytes/" + r.class, 0, func() (err error) { sinkNS, sinkU64, err = ParseBytes(idb); return }, cause},
			allocCase{"Decode/" + r.class, 0, func() (err error) { sinkU64, err = Decode(id); return }, cause},
			allocCase{"DecodeBytes/" + r.class, 0, func() (err error) { sinkU64, err = DecodeBytes(idb); return }, cause},
			allocCase{"Valid/" + r.class, 0, func() error { sinkBool = Valid(id); return validErr(sinkBool) }, ErrInvalid},
			allocCase{"ValidBytes/" + r.class, 0, func() error { sinkBool = ValidBytes(idb); return validErr(sinkBool) }, ErrInvalid},
		)
	}
	return cs
}

// TestAllocs is the allocation contract: every case's measured allocations per
// call must equal its want exactly — zero for the hot path and every refusal,
// one for a call whose product is a new string.
func TestAllocs(t *testing.T) {
	if raceEnabled {
		t.Skip("allocation counts are not meaningful under -race (see race_on_test.go)")
	}
	for _, c := range allocCases() {
		// The call must take the path being measured: success, or the named cause.
		if err := c.f(); c.err == nil && err != nil || c.err != nil && !errors.Is(err, c.err) {
			t.Errorf("%s: returned %v, want %v — the case does not exercise its path", c.name, err, c.err)
			continue
		}
		if got := testing.AllocsPerRun(1000, func() { _ = c.f() }); got != c.want {
			t.Errorf("%s: %v allocs/op, want %v", c.name, got, c.want)
		}
	}
}
