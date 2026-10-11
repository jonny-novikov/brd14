// gomem: how many bytes a 14- versus 16-byte string costs on the Go heap.
//
// Standard library only. It allocates n distinct strings of each width, forces
// a collection, and reads runtime.MemStats before and after: HeapAlloc gives
// the live bytes per string, BySize gives the allocator size class each width
// landed in (the "16" class takes every object of 9..16 bytes). A 17-byte
// string is measured too, as the control that shows the next class (24).
//
//	go run . -n 1000000      # prints one JSON object on stdout
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"runtime"
)

// alphabet is the brd14 alphabet; the strings are built to look like ids so
// nothing here depends on repeated content (Go does not intern, but the
// compiler folds constants, so every string is built from a changing buffer).
const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

type classDelta struct {
	Size    uint32 `json:"size"`
	Mallocs uint64 `json:"mallocs"`
}

type measurement struct {
	Width          int          `json:"width"`
	N              int          `json:"n"`
	HeapAllocDelta uint64       `json:"heap_alloc_delta"`
	BytesPerString float64      `json:"bytes_per_string"`
	MallocsDelta   uint64       `json:"mallocs_delta"`
	Classes        []classDelta `json:"size_class_mallocs"`
	// The slice of string headers costs 16 bytes per element on its own; it is
	// allocated before the baseline is read, so it is not in the delta.
	Note string `json:"note"`
}

func classes(m *runtime.MemStats) map[uint32]uint64 {
	out := make(map[uint32]uint64, len(m.BySize))
	for _, b := range m.BySize {
		out[b.Size] = b.Mallocs
	}
	return out
}

func measure(width, n int) measurement {
	keep := make([]string, n)
	buf := make([]byte, width)
	runtime.GC()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	for i := 0; i < n; i++ {
		v := i
		for j := width - 1; j >= 0; j-- {
			buf[j] = alphabet[v%62]
			v /= 62
		}
		keep[i] = string(buf) // one heap allocation of exactly `width` bytes
	}
	runtime.GC()
	runtime.ReadMemStats(&after)
	bc, ac := classes(&before), classes(&after)
	var cls []classDelta
	for _, s := range []uint32{8, 16, 24, 32, 48} {
		cls = append(cls, classDelta{Size: s, Mallocs: ac[s] - bc[s]})
	}
	runtime.KeepAlive(keep)
	return measurement{
		Width:          width,
		N:              n,
		HeapAllocDelta: after.HeapAlloc - before.HeapAlloc,
		BytesPerString: float64(after.HeapAlloc-before.HeapAlloc) / float64(n),
		MallocsDelta:   after.Mallocs - before.Mallocs,
		Classes:        cls,
		Note:           "HeapAlloc delta over n strings; the []string holding them is allocated before the baseline",
	}
}

func main() {
	n := flag.Int("n", 1_000_000, "strings per width")
	flag.Parse()
	out := map[string]any{
		"runtime":             runtime.Version(),
		"goos":                runtime.GOOS,
		"goarch":              runtime.GOARCH,
		"string_header_bytes": 16, // the (ptr, len) header lives in the []string, not in the delta
		"measurements": []measurement{
			measure(14, *n),
			measure(16, *n),
			measure(17, *n),
		},
	}
	enc := json.NewEncoder(os.Stdout)
	if err := enc.Encode(out); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
