package main

import (
	"strings"
	"testing"
)

const sample = `goos: linux
goarch: amd64
pkg: github.com/jonny-novikov/brd14/go
cpu: Intel(R) Xeon(R) Processor @ 2.10GHz
BenchmarkEncode           	 6818071	        40.00 ns/op	      16 B/op	       1 allocs/op
BenchmarkEncodeAppend-4   	16353878	        16.00 ns/op	       0 B/op	       0 allocs/op
BenchmarkEncode           	 6818071	        42.00 ns/op	      16 B/op	       1 allocs/op
BenchmarkEncodeAppend-4   	16353878	        18.00 ns/op	       0 B/op	       0 allocs/op
BenchmarkEncode           	 6818071	        41.00 ns/op	      16 B/op	       1 allocs/op
BenchmarkHash32-4         	247703851	         0.9651 ns/op
PASS
ok  	github.com/jonny-novikov/brd14/go	3.495s
`

func TestReduce(t *testing.T) {
	doc, err := reduce(strings.NewReader(sample), Doc{Impl: "go"})
	if err != nil {
		t.Fatal(err)
	}
	if doc.Machine != "Intel(R) Xeon(R) Processor @ 2.10GHz" {
		t.Errorf("machine = %q", doc.Machine)
	}
	want := []Result{
		{Op: "encode", NsPerOp: 41, MadNs: 1, Samples: 3, CV: 0.0244, AllocsPerOp: 1, BytesPerOp: 16},
		{Op: "encode_append", NsPerOp: 17, MadNs: 1, Samples: 2, CV: 0.0832, AllocsPerOp: 0, BytesPerOp: 0},
		{Op: "hash32", NsPerOp: 0.9651, MadNs: 0, Samples: 1, CV: 0, AllocsPerOp: -1, BytesPerOp: -1},
	}
	if len(doc.Results) != len(want) {
		t.Fatalf("results = %+v", doc.Results)
	}
	for i, w := range want {
		if doc.Results[i] != w {
			t.Errorf("result %d = %+v, want %+v", i, doc.Results[i], w)
		}
	}
}

func TestOpName(t *testing.T) {
	for in, want := range map[string]string{
		"BenchmarkEncode":         "encode",
		"BenchmarkEncodeAppend-4": "encode_append",
		"BenchmarkDecodeBytes":    "decode_bytes",
		"BenchmarkHash32-16":      "hash32",
		"BenchmarkMintAppend":     "mint_append",
	} {
		if got := opName(in); got != want {
			t.Errorf("opName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestReduceRejectsEmptyInput(t *testing.T) {
	if _, err := reduce(strings.NewReader("PASS\n"), Doc{}); err == nil {
		t.Fatal("no benchmark lines, no error")
	}
}
