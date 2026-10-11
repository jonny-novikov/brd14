package brd14

// The caller-owned-buffer API: AppendEncode, ParseBytes, DecodeBytes,
// ValidBytes, AppendNextBranded and NodeFrom.
//
// Each of these is a second spelling of something the string API already
// does, so the main thing to prove is that the two spellings never disagree —
// on any input, accepted or refused, down to the error cause. ParseBytes earns
// extra attention because it does not share Parse's range guard: Parse
// compares the payload bytes against "AzL8n0Y58m7", ParseBytes compares the
// (hi, lo) halves against (qa, rb). TestArithmeticGuardBoundary walks the
// neighbourhood where the two forms could part ways, with the expected answer
// computed by math/big rather than by either guard.

import (
	"bytes"
	"hash/fnv"
	"math/big"
	"strconv"
	"strings"
	"testing"
)

// TestAppendEncode: AppendEncode appends exactly Encode's bytes after whatever
// dst already holds, and a refusal hands dst back untouched.
func TestAppendEncode(t *testing.T) {
	prefix := []byte("ids: ")
	dst := append(make([]byte, 0, 64), prefix...)
	got, err := AppendEncode(dst, "USR", vecSnowUSR)
	if err != nil || string(got) != "ids: USR0KHTOWnGLuC" {
		t.Fatalf("AppendEncode = %q, %v; want %q", got, err, "ids: USR0KHTOWnGLuC")
	}
	if &got[0] != &dst[0] {
		t.Fatal("AppendEncode reallocated a dst with spare capacity")
	}

	for _, c := range []struct {
		ns   string
		snow uint64
		err  error
	}{
		{"usr", vecSnowUSR, ErrNamespace},
		{"US", 1 << 63, ErrNamespace},
		{"USR", 1 << 63, ErrRange},
	} {
		dst := append(make([]byte, 0, 64), prefix...)
		got, err := AppendEncode(dst, c.ns, c.snow)
		if err != c.err {
			t.Errorf("AppendEncode(%q, %d) err = %v, want %v", c.ns, c.snow, err, c.err)
		}
		if len(got) != len(dst) || cap(got) != cap(dst) || &got[0] != &dst[0] || !bytes.Equal(got[:cap(got)], dst[:cap(dst)]) {
			t.Errorf("AppendEncode(%q, %d) refused but changed dst: %q", c.ns, c.snow, got)
		}
	}
	if got, err := AppendEncode(nil, "ZZZ", 0); err != nil || string(got) != "ZZZ00000000000" {
		t.Errorf("AppendEncode(nil, ZZZ, 0) = %q, %v", got, err)
	}

	r := pinnedRand(10)
	buf := make([]byte, 0, Len)
	for i := 0; i < 20000; i++ {
		ns, snow := randNS(r), r.Uint64()>>1
		want := MustEncode(ns, snow)
		var err error
		if buf, err = AppendEncode(buf[:0], ns, snow); err != nil || string(buf) != want {
			t.Fatalf("AppendEncode(%q, %d) = %q, %v; Encode says %q", ns, snow, buf, err, want)
		}
	}
}

// assertParseFormsAgree checks every decode entry point against Parse on one
// input: the same verdict, the same cause, the same namespace and snowflake.
func assertParseFormsAgree(t *testing.T, id string) {
	t.Helper()
	ns, snow, err := Parse(id)
	b := []byte(id)
	bns, bsnow, berr := ParseBytes(b)
	if berr != err || bsnow != snow || (err == nil && string(bns[:]) != ns) || (err != nil && bns != [3]byte{}) {
		t.Fatalf("%q: ParseBytes = (%q, %d, %v), Parse = (%q, %d, %v)", id, bns[:], bsnow, berr, ns, snow, err)
	}
	if d, derr := DecodeBytes(b); d != snow || derr != err {
		t.Fatalf("%q: DecodeBytes = (%d, %v), Parse = (%d, %v)", id, d, derr, snow, err)
	}
	if ValidBytes(b) != (err == nil) {
		t.Fatalf("%q: ValidBytes = %v, Parse err = %v", id, ValidBytes(b), err)
	}
}

// TestParseBytesAgreesWithParse drives both decoders over arbitrary bytes at
// every length spanning Len, and over single-byte corruptions of real ids —
// the inputs closest to valid, where a guard or a table slip would show.
func TestParseBytesAgreesWithParse(t *testing.T) {
	r := pinnedRand(11)
	for l := 0; l <= 20; l++ {
		for i := 0; i < 500; i++ {
			b := make([]byte, l)
			for j := range b {
				b[j] = byte(r.UintN(256))
			}
			assertParseFormsAgree(t, string(b))
		}
	}
	for _, seed := range []string{"USR0KHTOWnGLuC", "ZZZ" + maxPayload, "ABC00000000000", "SESzzzzzzzzzzz"} {
		for pos := 0; pos < Len; pos++ {
			for c := 0; c < 256; c++ {
				b := []byte(seed)
				b[pos] = byte(c)
				assertParseFormsAgree(t, string(b))
			}
		}
	}
	for i := 0; i < 20000; i++ {
		assertParseFormsAgree(t, MustEncode(randNS(r), r.Uint64()>>1))
	}
}

// TestParseBytesDoesNotAlias: the namespace comes back by value, so reusing
// the input buffer cannot rewrite a result already handed out.
func TestParseBytesDoesNotAlias(t *testing.T) {
	b := []byte("USR0KHTOWnGLuC")
	ns, snow, err := ParseBytes(b)
	copy(b, "SES00000000000")
	if err != nil || string(ns[:]) != "USR" || snow != vecSnowUSR {
		t.Fatalf("after reusing the buffer: ns=%q snow=%d err=%v", ns[:], snow, err)
	}
}

// TestArithmeticGuardConstants pins the identity the arithmetic guard rests
// on, 2^63-1 = qa·62^6 + rb with rb < 62^6, so (qa, rb) is the quotient and
// remainder and not merely some pair that sums right.
func TestArithmeticGuardConstants(t *testing.T) {
	p6 := new(big.Int).Exp(big.NewInt(62), big.NewInt(6), nil)
	if p6.Uint64() != pow62x6 {
		t.Fatalf("pow62x6 = %d, want 62^6 = %s", uint64(pow62x6), p6)
	}
	q, m := new(big.Int).DivMod(new(big.Int).SetUint64(maxSnowflake), p6, new(big.Int))
	if q.Uint64() != qa || m.Uint64() != rb {
		t.Fatalf("divmod(2^63-1, 62^6) = (%s, %s), want (qa=%d, rb=%d)", q, m, qa, rb)
	}
}

// base62Big renders v as exactly 11 base62 digits with math/big — an encoder
// that shares nothing with put — or reports false when v needs more digits.
func base62Big(v *big.Int) (string, bool) {
	var d [11]byte
	x := new(big.Int).Set(v)
	r := new(big.Int)
	b62 := big.NewInt(62)
	for i := 10; i >= 0; i-- {
		x.DivMod(x, b62, r)
		d[i] = alphabet[r.Int64()]
	}
	return string(d[:]), x.Sign() == 0
}

// TestArithmeticGuardBoundary walks both guards across the domain's edge: the
// values around 2^63-1, and the (hi, lo) grid around (qa, rb), including the
// combinations a guard that tested only hi, or compared lo with < for <=, or
// forgot the hi == qa case would get wrong. Expected verdicts come from
// math/big.
func TestArithmeticGuardBoundary(t *testing.T) {
	top := new(big.Int).SetUint64(maxSnowflake)
	check := func(v *big.Int) {
		t.Helper()
		payload, ok := base62Big(v)
		if !ok {
			return // needs a 12th digit: not an 11-digit payload at all
		}
		id := "RNG" + payload
		assertParseFormsAgree(t, id)
		_, snow, err := ParseBytes([]byte(id))
		if inRange := v.Cmp(top) <= 0; inRange {
			if err != nil || snow != v.Uint64() {
				t.Fatalf("%s (= %s): ParseBytes = %d, %v; want %s", id, v, snow, err, v)
			}
		} else if err != ErrRange {
			t.Fatalf("%s (= %s > 2^63-1): ParseBytes err = %v, want ErrRange", id, v, err)
		}
	}

	for d := int64(-300); d <= 300; d++ {
		check(new(big.Int).Add(top, big.NewInt(d)))
	}
	p6 := new(big.Int).SetUint64(pow62x6)
	for _, hi := range []int64{0, 1, qa - 1, qa, qa + 1, 62*62*62*62*62 - 1} {
		for _, lo := range []int64{0, 1, rb - 1, rb, rb + 1, rb + 62, pow62x6 - 1} {
			v := new(big.Int).Mul(big.NewInt(hi), p6)
			check(v.Add(v, big.NewInt(lo)))
		}
	}
}

// TestAppendNextBranded: the appending mint is the same mint — valid,
// strictly increasing, on the generator's node — and a refusal leaves dst as
// it was.
func TestAppendNextBranded(t *testing.T) {
	g := NewGenerator(613)
	buf := make([]byte, 0, 2*Len)
	var prev uint64
	for i := 0; i < 5000; i++ {
		var err error
		buf, err = g.AppendNextBranded(buf[:0], "SES")
		if err != nil {
			t.Fatalf("mint %d: %v", i, err)
		}
		ns, snow, perr := ParseBytes(buf)
		if perr != nil || string(ns[:]) != "SES" || NodeOf(snow) != 613 || snow <= prev {
			t.Fatalf("mint %d: %q parsed to ns=%q snow=%d err=%v (prev %d)", i, buf, ns[:], snow, perr, prev)
		}
		prev = snow
	}
	dst := []byte("keep")
	if got, err := g.AppendNextBranded(dst, "se"); err != ErrNamespace || string(got) != "keep" {
		t.Fatalf("AppendNextBranded(se) = %q, %v; want dst unchanged and ErrNamespace", got, err)
	}
}

// TestNodeFromMatchesHashFNV holds the hand-written FNV-32a to the standard
// library's, over arbitrary host bytes and the full int range of pids —
// negative ones included, which the contract never sends but strconv renders
// with a sign, and NodeFrom must too.
func TestNodeFromMatchesHashFNV(t *testing.T) {
	ref := func(host string, pid int) uint64 {
		h := fnv.New32a()
		h.Write([]byte(host))
		h.Write([]byte(strconv.Itoa(pid)))
		return uint64(h.Sum32()) & nodeMask
	}
	r := pinnedRand(12)
	hosts := []string{"", "hosta", "хост", strings.Repeat("a", 255), "\x00\xff"}
	pids := []int{0, 1, 100, 4242, 1<<31 - 1, -1, -100, int(^uint(0) >> 1), -int(^uint(0)>>1) - 1}
	for i := 0; i < 2000; i++ {
		b := make([]byte, r.UintN(48))
		for j := range b {
			b[j] = byte(r.UintN(256))
		}
		hosts = append(hosts, string(b))
		pids = append(pids, int(r.Int64()))
	}
	for i, host := range hosts {
		pid := pids[i%len(pids)]
		if got, want := NodeFrom(host, pid), ref(host, pid); got != want {
			t.Fatalf("NodeFrom(%q, %d) = %d, hash/fnv says %d", host, pid, got, want)
		}
	}
}
