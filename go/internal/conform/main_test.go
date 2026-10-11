package main

// The shim's own protocol handling. Its ANSWERS are judged by tools/parity.py
// against the oracle; what that driver cannot see is how the shim treats a
// request it should never receive, so that is pinned here: a malformed request
// is an error, never a guessed answer.

import (
	"bufio"
	"bytes"
	"strings"
	"testing"
)

func run(t *testing.T, input string) (string, error) {
	t.Helper()
	var out bytes.Buffer
	w := bufio.NewWriter(&out)
	err := serve(bufio.NewReader(strings.NewReader(input)), w)
	if ferr := w.Flush(); ferr != nil {
		t.Fatal(ferr)
	}
	return out.String(), err
}

func TestServeAnswers(t *testing.T) {
	in := strings.Join([]string{
		"E 555352 274557032793636864",    // V-1
		"E 757372 9223372036854775808",   // usr, 2^63: NAMESPACE beats RANGE
		"E 555352 9223372036854775808",   // USR, 2^63: RANGE
		"E - 0",                          // empty namespace
		"D 555352304e6757456641454a6673", // V-2
		"D 7573727a7a7a7a7a7a7a7a7a7a21", // usrzzzzzzzzzz!: NAMESPACE
		"D 5553527a7a7a7a7a7a7a7a7a7a21", // USRzzzzzzzzzz!: CHARSET beats RANGE
		"D 5553527a7a7a7a7a7a7a7a7a7a7a", // USRzzzzzzzzzzz: RANGE
		"D 555352304b48544f576e474c75",   // USR0KHTOWnGLu, 13 bytes: LENGTH
		"D -",                            // empty: LENGTH
		"H 274557032793636864",           // V-6
		"U 274557032793636864",           // E-1
		"F 274557032793636864",
		"N 686f737461 100", // N-1
		"N - 101",
		"",
	}, "\n")
	want := strings.Join([]string{
		"HELLO go reference EDHUFN",
		"OK USR0KHTOWnGLuC",
		"ERR NAMESPACE",
		"ERR RANGE",
		"ERR NAMESPACE",
		"OK USR 320636799581945856",
		"ERR NAMESPACE",
		"ERR CHARSET",
		"ERR RANGE",
		"ERR LENGTH",
		"ERR LENGTH",
		"OK 234878118",
		"OK 1769526697641",
		"OK 65459497641 0 0",
		"OK 585",
		"OK 559",
		"",
	}, "\n")
	got, err := run(t, in)
	if err != nil || got != want {
		t.Fatalf("serve: err=%v\n got:\n%s\nwant:\n%s", err, got, want)
	}
}

// TestServeEOF: an empty input is a HELLO and nothing else (the driver's probe
// for the supported ops), and a last line without a newline is still answered.
func TestServeEOF(t *testing.T) {
	if got, err := run(t, ""); err != nil || got != hello {
		t.Fatalf("empty input: %q, %v", got, err)
	}
	if got, err := run(t, "H 0"); err != nil || got != hello+"OK 0\n" {
		t.Fatalf("unterminated last line: %q, %v", got, err)
	}
}

func TestServeRejectsMalformedRequests(t *testing.T) {
	for _, bad := range []string{
		"X 1",                    // unknown op
		"HX 1",                   // op longer than one byte
		"H",                      // missing argument
		"H 1 2",                  // extra argument
		"E 555352",               // missing argument
		"H  1",                   // empty argument
		"H 1 ",                   // trailing space
		"H -1",                   // not unsigned
		"H 18446744073709551616", // 2^64
		"D 5",                    // odd-length hex
		"D zz",                   // not hex
		"N 6869 x",               // pid not decimal
	} {
		if _, err := run(t, bad+"\n"); err == nil {
			t.Errorf("request %q was answered, want a protocol error", bad)
		}
	}
}
