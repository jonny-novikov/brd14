package brd14

// The typed causes and the contract's precedence table.
//
// Every refusal still satisfies ErrInvalid — that promise is v0.1.0's and the
// rest of the suite already leans on it. What this file adds is the WHICH: each
// refusal names exactly one cause, and when an input breaks several rules the
// cause is the one docs/contract.md ranks first. The multi-fault rows are the
// load-bearing ones: a single-fault input is refused identically under every
// ordering of the checks, so only an input that breaks two rules at once can
// tell a correct ordering from a reordered one.

import (
	"errors"
	"strings"
	"testing"
)

// causes lists the typed causes by their contract class name, in code order.
var causes = []struct {
	class string
	err   error
}{
	{"LENGTH", ErrLength},
	{"NAMESPACE", ErrNamespace},
	{"CHARSET", ErrCharset},
	{"RANGE", ErrRange},
}

// classOf names the ONE cause err matches, failing the test when it matches
// none (a foreign error or bare ErrInvalid) or several (the causes are no
// longer distinct). It also insists every cause still satisfies ErrInvalid.
func classOf(t *testing.T, err error) string {
	t.Helper()
	if err == nil {
		return "OK"
	}
	if !errors.Is(err, ErrInvalid) {
		t.Fatalf("error %v does not satisfy errors.Is(err, ErrInvalid)", err)
	}
	var hit []string
	for _, c := range causes {
		if errors.Is(err, c.err) {
			hit = append(hit, c.class)
		}
	}
	if len(hit) != 1 {
		t.Fatalf("error %v matches causes %v, want exactly one", err, hit)
	}
	return hit[0]
}

// TestCausesAreDistinctAndInvalid pins the error model itself: four distinct
// values, each an ErrInvalid, none of which ErrInvalid (or a policy refusal)
// can impersonate.
func TestCausesAreDistinctAndInvalid(t *testing.T) {
	for i, a := range causes {
		if !errors.Is(a.err, ErrInvalid) {
			t.Errorf("%s does not satisfy errors.Is(_, ErrInvalid)", a.class)
		}
		if !strings.HasPrefix(a.err.Error(), ErrInvalid.Error()+": ") {
			t.Errorf("%s message %q does not extend %q", a.class, a.err, ErrInvalid)
		}
		for j, b := range causes {
			if i != j && (a.err == b.err || errors.Is(a.err, b.err)) {
				t.Errorf("%s satisfies errors.Is(_, %s): the causes are not distinct", a.class, b.class)
			}
		}
		// The sentinel is the parent, never a child: a bare ErrInvalid (which
		// no function here returns any more) must not pass for a cause.
		if errors.Is(ErrInvalid, a.err) {
			t.Errorf("ErrInvalid satisfies errors.Is(_, %s)", a.class)
		}
		if errors.Is(ErrRefused, a.err) || errors.Is(a.err, ErrRefused) {
			t.Errorf("%s and ErrRefused are conflated", a.class)
		}
	}
}

// TestDecodeClasses is one row per class, through every decode entry point.
func TestDecodeClasses(t *testing.T) {
	for _, c := range []struct{ id, class string }{
		{"USR0KHTOWnGLuC", "OK"},
		{"USR" + maxPayload, "OK"},
		{"", "LENGTH"},
		{"USR0KHTOWnGLu", "LENGTH"},
		{"USR0KHTOWnGLuCC", "LENGTH"},
		{"日本語のテスト", "LENGTH"}, // 21 bytes: classified on bytes, not runes
		{"usr0KHTOWnGLuC", "NAMESPACE"},
		{"US10KHTOWnGLuC", "NAMESPACE"},
		{"U\x00R0KHTOWnGLuC", "NAMESPACE"},
		{"@AB0KHTOWnGLuC", "NAMESPACE"}, // '@' is 'A'-1
		{"AB[0KHTOWnGLuC", "NAMESPACE"}, // '[' is 'Z'+1
		{"USR0KHTOWnGLu!", "CHARSET"},
		{"USR0KHTOWnGLu ", "CHARSET"},
		{"USR/0000000000", "CHARSET"}, // '/' is '0'-1
		{"USR:0000000000", "CHARSET"}, // ':' is '9'+1
		{"USR`0000000000", "CHARSET"}, // '`' is 'a'-1
		{"USR\xff0000000000", "CHARSET"},
		{"USRzzzzzzzzzzz", "RANGE"},
		{"USRAzL8n0Y58m8", "RANGE"}, // the successor of the maximum: numerically 2^63
		{"USRB0000000000", "RANGE"},
	} {
		_, _, err := Parse(c.id)
		if got := classOf(t, err); got != c.class {
			t.Errorf("Parse(%q): class %s, want %s (err=%v)", c.id, got, c.class, err)
		}
		if _, derr := Decode(c.id); derr != err {
			t.Errorf("Decode(%q) = %v, Parse said %v", c.id, derr, err)
		}
		if Valid(c.id) != (c.class == "OK") {
			t.Errorf("Valid(%q) = %v, want %v", c.id, Valid(c.id), c.class == "OK")
		}
	}
}

// TestEncodeClasses is one row per class through Encode, MustEncode and the
// minter's codec path.
func TestEncodeClasses(t *testing.T) {
	for _, c := range []struct {
		ns    string
		snow  uint64
		class string
	}{
		{"USR", 0, "OK"},
		{"ZZZ", maxSnowflake, "OK"},
		{"", 0, "NAMESPACE"},
		{"US", 0, "NAMESPACE"},
		{"USRR", 0, "NAMESPACE"},
		{"usr", 0, "NAMESPACE"},
		{"US1", 0, "NAMESPACE"},
		{"ÄÖ", 0, "NAMESPACE"}, // 4 bytes, 2 runes
		{"USR", 1 << 63, "RANGE"},
		{"USR", ^uint64(0), "RANGE"},
	} {
		id, err := Encode(c.ns, c.snow)
		if got := classOf(t, err); got != c.class {
			t.Errorf("Encode(%q, %d): class %s, want %s", c.ns, c.snow, got, c.class)
		}
		if err != nil && id != "" {
			t.Errorf("Encode(%q, %d) refused but returned %q", c.ns, c.snow, id)
		}
		if err != nil {
			func() {
				defer func() {
					if p, _ := recover().(error); p != err {
						t.Errorf("MustEncode(%q, %d) panicked with %v, want %v", c.ns, c.snow, p, err)
					}
				}()
				MustEncode(c.ns, c.snow)
			}()
		}
	}
	// The minter's codec check reports the same cause once its gate admits.
	if _, err := NewMinter(NewGenerator(1), nil).Mint("zz1"); !errors.Is(err, ErrNamespace) {
		t.Errorf("Mint(zz1) with a nil gate = %v, want ErrNamespace", err)
	}
	if _, err := NewGenerator(1).NextBranded("US"); !errors.Is(err, ErrNamespace) {
		t.Errorf("NextBranded(US) = %v, want ErrNamespace", err)
	}
}

// TestDecodePrecedence feeds inputs that break two or three rules at once. Each
// row names the rule that must win and the one(s) it beats; a reordering of
// Parse's checks moves at least one row to the losing class.
func TestDecodePrecedence(t *testing.T) {
	for _, c := range []struct{ id, class, beats string }{
		{"usr0KHTOWnGLu", "LENGTH", "NAMESPACE"},
		{"usr", "LENGTH", "NAMESPACE"},
		{"US!", "LENGTH", "NAMESPACE"},
		{"USR0KHTOWnGL!", "LENGTH", "CHARSET"},
		{"USRzzzzzzzzzzzz", "LENGTH", "RANGE"},
		{"usr0KHTOWnGL!!", "NAMESPACE", "CHARSET"},
		{"usrzzzzzzzzzzz", "NAMESPACE", "RANGE"},
		{"usrzzzzzzzzzz!", "NAMESPACE", "CHARSET, RANGE"},
		{"USRzzzzzzzzzz!", "CHARSET", "RANGE"},
		// '{' and '~' sort ABOVE 'z', so these payloads are lexicographically
		// above "AzL8n0Y58m7" as well as off-alphabet. A range guard that ran
		// before the charset loop — v0.1.0's order — reports RANGE here.
		{"USR{0000000000", "CHARSET", "RANGE"},
		{"USR~0000000000", "CHARSET", "RANGE"},
		{"USRz{000000000", "CHARSET", "RANGE"},
		{"USRzzzzzzzzzz\xff", "CHARSET", "RANGE"},
	} {
		_, _, err := Parse(c.id)
		if got := classOf(t, err); got != c.class {
			t.Errorf("Parse(%q): class %s, want %s (it must beat %s)", c.id, got, c.class, c.beats)
		}
	}
}

// TestEncodePrecedence: a namespace fault outranks a range fault, whatever the
// namespace's length.
func TestEncodePrecedence(t *testing.T) {
	for _, ns := range []string{"", "U", "US", "usr", "USRR", "US1", "\xff\xff\xff"} {
		for _, snow := range []uint64{1 << 63, 1<<63 + 1, 3 << 62, ^uint64(0)} {
			if _, err := Encode(ns, snow); classOf(t, err) != "NAMESPACE" {
				t.Errorf("Encode(%q, %d) = %v, want NAMESPACE (it must beat RANGE)", ns, snow, err)
			}
		}
	}
}
