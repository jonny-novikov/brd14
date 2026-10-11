package brd14

// Native fuzz targets: `make harden` runs each for 10 s; a plain `go test`
// runs only their seed corpora, as ordinary tests.
//
// The judge inside each target is not the package itself. refDecode and
// refEncode restate the contract the slow, obvious way — a byte-set check per
// rule in precedence order, math/big for the value, the way tools/oracle.py
// does it — so the fuzzer hunts for any input on which the codec and the
// contract part ways, not merely for inputs on which two halves of the codec
// disagree with each other (FuzzParse checks that too: Parse and ParseBytes use
// different range guards).

import (
	"bytes"
	"math/big"
	"strings"
	"testing"
)

var bigMax = new(big.Int).SetUint64(maxSnowflake)

// refDecode is the contract's decode, from docs/contract.md alone: the class
// name ("OK" on success) and the value.
func refDecode(b []byte) (string, *big.Int) {
	if len(b) != Len {
		return "LENGTH", nil
	}
	for _, c := range b[:3] {
		if c < 'A' || c > 'Z' {
			return "NAMESPACE", nil
		}
	}
	v := new(big.Int)
	for _, c := range b[3:] {
		d := strings.IndexByte(alphabet, c)
		if d < 0 {
			return "CHARSET", nil
		}
		v.Mul(v, big.NewInt(62)).Add(v, big.NewInt(int64(d)))
	}
	if v.Cmp(bigMax) > 0 {
		return "RANGE", nil
	}
	return "OK", v
}

// refEncode is the contract's encode: the class name and, on success, the id.
func refEncode(ns string, snow uint64) (string, string) {
	if len(ns) != 3 || strings.Trim(ns, "ABCDEFGHIJKLMNOPQRSTUVWXYZ") != "" {
		return "NAMESPACE", ""
	}
	if snow > maxSnowflake {
		return "RANGE", ""
	}
	payload, _ := base62Big(new(big.Int).SetUint64(snow)) // from api_test.go
	return "OK", ns + payload
}

func FuzzParse(f *testing.F) {
	for _, s := range []string{
		"USR0KHTOWnGLuC", "USR0NgWEfAEJfs", "ABC00000000000", "ZZZ" + maxPayload,
		"USRAzL8n0Y58m8", "USRzzzzzzzzzzz", "usr0KHTOWnGLuC", "USR0KHTOWnGLu", "USR0KHTOWnGLuCC",
		"usr0KHTOWnGL!!", "USRzzzzzzzzzz!", "USR{0000000000", "", "U", "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff",
	} {
		f.Add([]byte(s))
	}
	f.Fuzz(func(t *testing.T, b []byte) {
		id := string(b)
		ns, snow, err := Parse(id)
		bns, bsnow, berr := ParseBytes(b)

		// Totality, exactly one typed cause, and the contract's class.
		class, want := refDecode(b)
		if got := classOf(t, err); got != class {
			t.Fatalf("Parse(%q): class %s, the contract says %s", b, got, class)
		}
		// Parse and ParseBytes — two range guards — give one answer.
		if berr != err || bsnow != snow || (err == nil && string(bns[:]) != ns) {
			t.Fatalf("%q: ParseBytes = (%q, %d, %v), Parse = (%q, %d, %v)", b, bns[:], bsnow, berr, ns, snow, err)
		}
		if Valid(id) != (err == nil) || ValidBytes(b) != (err == nil) {
			t.Fatalf("%q: Valid/ValidBytes disagree with Parse (%v)", b, err)
		}
		if err != nil {
			if ns != "" || snow != 0 || bns != [3]byte{} {
				t.Fatalf("%q: refusal returned (%q, %d, %q), want zero values", b, ns, snow, bns[:])
			}
			return
		}
		// Round trip: an accepted id is exactly what Encode makes of its parts.
		if want.Uint64() != snow {
			t.Fatalf("%q: Parse = %d, the contract says %s", b, snow, want)
		}
		if re, err := Encode(ns, snow); err != nil || re != id {
			t.Fatalf("%q: Encode(Parse(id)) = %q, %v", b, re, err)
		}
		if re, err := AppendEncode(nil, ns, snow); err != nil || !bytes.Equal(re, b) {
			t.Fatalf("%q: AppendEncode(Parse(id)) = %q, %v", b, re, err)
		}
	})
}

func FuzzAppendEncode(f *testing.F) {
	f.Add("USR", uint64(274557032793636864), []byte(""))
	f.Add("ABC", uint64(0), []byte("prefix "))
	f.Add("ZZZ", uint64(maxSnowflake), []byte{0xff})
	f.Add("ZZZ", uint64(1)<<63, []byte("x"))
	f.Add("usr", uint64(1)<<63, []byte("x"))
	f.Add("US", uint64(1), []byte(nil))
	f.Add("USRR", ^uint64(0), []byte("ab"))
	f.Fuzz(func(t *testing.T, ns string, snow uint64, prefix []byte) {
		class, wantID := refEncode(ns, snow)
		dst := append(make([]byte, 0, len(prefix)+Len), prefix...)
		out, err := AppendEncode(dst, ns, snow)
		if got := classOf(t, err); got != class {
			t.Fatalf("AppendEncode(%q, %d): class %s, the contract says %s", ns, snow, got, class)
		}
		id, eerr := Encode(ns, snow)
		if eerr != err {
			t.Fatalf("(%q, %d): Encode err %v, AppendEncode err %v", ns, snow, eerr, err)
		}
		if err != nil {
			if len(out) != len(dst) || !bytes.Equal(out, prefix) || id != "" {
				t.Fatalf("(%q, %d): refused, but dst became %q (Encode %q)", ns, snow, out, id)
			}
			return
		}
		if !bytes.Equal(out[:len(prefix)], prefix) || string(out[len(prefix):]) != wantID || id != wantID {
			t.Fatalf("(%q, %d): AppendEncode = %q, Encode = %q, the contract says %q after %q", ns, snow, out, id, wantID, prefix)
		}
		if &out[0] != &dst[:1][0] {
			t.Fatalf("(%q, %d): AppendEncode reallocated a dst with room for the id", ns, snow)
		}
		if pns, psnow, perr := ParseBytes(out[len(prefix):]); perr != nil || string(pns[:]) != ns || psnow != snow {
			t.Fatalf("(%q, %d): round trip = (%q, %d, %v)", ns, snow, pns[:], psnow, perr)
		}
	})
}
