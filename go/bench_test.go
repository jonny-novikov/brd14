package brd14

// The benches, under bench/README.md's protocol: one benchmark per operation,
// each walking the 4096-row corpus in order (i & corpusMask) so no branch
// predictor can memorise a single input, each reporting allocations, each
// feeding its results into an accumulator that reaches a package-level sink so
// the compiler cannot delete the work. `make bench` runs them ten times pinned
// to one core and internal/benchjson reduces the samples to the shared JSON
// schema; the names below become the op names there (BenchmarkEncodeAppend ->
// encode_append).
//
// Written against b.N, not b.Loop: the module's floor is Go 1.22.

import "testing"

func BenchmarkEncode(b *testing.B) {
	c := corpus(b)
	b.ReportAllocs()
	b.ResetTimer()
	var acc uint64
	for i := 0; i < b.N; i++ {
		j := i & corpusMask
		id, _ := Encode(c.ns[j], c.snow[j])
		acc += uint64(id[Len-1])
	}
	sinkU64 = acc
}

func BenchmarkEncodeAppend(b *testing.B) {
	c := corpus(b)
	buf := make([]byte, 0, Len)
	b.ReportAllocs()
	b.ResetTimer()
	var acc uint64
	for i := 0; i < b.N; i++ {
		j := i & corpusMask
		buf, _ = AppendEncode(buf[:0], c.ns[j], c.snow[j])
		acc += uint64(buf[Len-1])
	}
	sinkU64 = acc
}

func BenchmarkDecode(b *testing.B) {
	c := corpus(b)
	b.ReportAllocs()
	b.ResetTimer()
	var acc uint64
	for i := 0; i < b.N; i++ {
		off := (i & corpusMask) * Len
		ns, snow, _ := Parse(c.ids[off : off+Len])
		acc += snow + uint64(len(ns))
	}
	sinkU64 = acc
}

func BenchmarkDecodeBytes(b *testing.B) {
	c := corpus(b)
	b.ReportAllocs()
	b.ResetTimer()
	var acc uint64
	for i := 0; i < b.N; i++ {
		off := (i & corpusMask) * Len
		ns, snow, _ := ParseBytes(c.idb[off : off+Len])
		acc += snow + uint64(ns[0])
	}
	sinkU64 = acc
}

func BenchmarkValid(b *testing.B) {
	c := corpus(b)
	b.ReportAllocs()
	b.ResetTimer()
	var acc uint64
	for i := 0; i < b.N; i++ {
		off := (i & corpusMask) * Len
		if Valid(c.ids[off : off+Len]) {
			acc++
		}
	}
	sinkU64 = acc
}

func BenchmarkHash32(b *testing.B) {
	c := corpus(b)
	b.ReportAllocs()
	b.ResetTimer()
	var acc uint64
	for i := 0; i < b.N; i++ {
		acc += uint64(Hash32(c.snow[i&corpusMask]))
	}
	sinkU64 = acc
}

// The mint benches read the clock and CAS one cell, so they measure the
// generator, not the corpus; the corpus supplies only the namespace.

func BenchmarkMint(b *testing.B) {
	c := corpus(b)
	g := NewGenerator(613)
	b.ReportAllocs()
	b.ResetTimer()
	var acc uint64
	for i := 0; i < b.N; i++ {
		id, _ := g.NextBranded(c.ns[i&corpusMask])
		acc += uint64(id[Len-1])
	}
	sinkU64 = acc
}

func BenchmarkMintAppend(b *testing.B) {
	c := corpus(b)
	g := NewGenerator(613)
	buf := make([]byte, 0, Len)
	b.ReportAllocs()
	b.ResetTimer()
	var acc uint64
	for i := 0; i < b.N; i++ {
		buf, _ = g.AppendNextBranded(buf[:0], c.ns[i&corpusMask])
		acc += uint64(buf[Len-1])
	}
	sinkU64 = acc
}

func BenchmarkNext(b *testing.B) {
	g := NewGenerator(613)
	b.ReportAllocs()
	b.ResetTimer()
	var acc uint64
	for i := 0; i < b.N; i++ {
		acc += g.Next()
	}
	sinkU64 = acc
}
