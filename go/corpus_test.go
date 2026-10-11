package brd14

// The bench corpus, reproducible without the repository.
//
// bench/README.md fixes the corpus every runtime benchmarks: the first 4096
// rows of vectors/valid.tsv. A published module has no vectors/, so the
// benches fall back to regenerating those rows here — with the same splitmix64
// stream, the same seed and the same draw order as tools/vectorgen.py — rather
// than to some other "representative" corpus whose numbers would not compare.
// TestBenchCorpusMatchesVectors holds the regeneration to the committed file,
// row for row, whenever the file is present.

import (
	"errors"
	"io/fs"
	"os"
	"strconv"
	"strings"
	"testing"
)

const (
	corpusN    = 4096 // a power of two: the benches index with i & corpusMask
	corpusMask = corpusN - 1
	corpusSeed = 0x0B4D14_0001 // vectorgen.py SEED_VALID
)

// splitMix64 is tools/oracle.py's SplitMix64 (Steele, Lea & Flood, 2014),
// draw for draw.
type splitMix64 struct{ state uint64 }

func (r *splitMix64) next() uint64 {
	r.state += 0x9E3779B97F4A7C15
	z := r.state
	z = (z ^ z>>30) * 0xBF58476D1CE4E5B9
	z = (z ^ z>>27) * 0x94D049BB133111EB
	return z ^ z>>31
}

// below is uniform in [0, n) by rejection, exactly as the oracle draws it: a
// draw is kept iff it is below the largest multiple of n that fits in 2^64.
func (r *splitMix64) below(n uint64) uint64 {
	rem := (^uint64(0)%n + 1) % n // 2^64 mod n
	for {
		x := r.next()
		if rem == 0 || x < -rem { // -rem == 2^64 - rem: the rejection limit
			return x % n
		}
	}
}

func (r *splitMix64) ns() string {
	return string([]byte{byte('A' + r.below(26)), byte('A' + r.below(26)), byte('A' + r.below(26))})
}

// benchCorpus is the 4096-row corpus laid out for the benches. The ids are
// stored back to back, once as a string and once as bytes, and every decode
// bench slices row j out at j*Len: the string and byte benches walk identical
// memory with identical arithmetic and differ only in the type they pass.
type benchCorpus struct {
	source string
	ns     []string
	snow   []uint64
	ids    string // row j is ids[j*Len : (j+1)*Len]
	idb    []byte // the same bytes
}

func newBenchCorpus(source string, ns []string, snow []uint64) *benchCorpus {
	c := &benchCorpus{source: source, ns: ns, snow: snow}
	for i := range snow {
		c.idb = append(c.idb, MustEncode(ns[i], snow[i])...)
	}
	c.ids = string(c.idb)
	return c
}

// generatedCorpus regenerates vectors/valid.tsv rows 1..4096.
func generatedCorpus() *benchCorpus {
	r := &splitMix64{state: corpusSeed}
	ns, snow := make([]string, corpusN), make([]uint64, corpusN)
	for i := range snow {
		ns[i] = r.ns() // the oracle draws the namespace first, then the value
		snow[i] = r.next() >> 1
	}
	return newBenchCorpus("splitmix64 seed 0xb4d140001 (vectorgen's corpus, regenerated in-test)", ns, snow)
}

// fileCorpus reads the first 4096 rows of vectors/valid.tsv.
func fileCorpus() (*benchCorpus, error) {
	rows, err := readVectors("valid.tsv", 8)
	if err != nil {
		return nil, err
	}
	if len(rows) < corpusN {
		return nil, errors.New("valid.tsv is shorter than the 4096-row bench corpus")
	}
	ns, snow := make([]string, corpusN), make([]uint64, corpusN)
	for i, r := range rows[:corpusN] {
		ns[i] = r[0]
		if snow[i], err = strconv.ParseUint(r[1], 10, 64); err != nil {
			return nil, err
		}
	}
	return newBenchCorpus("vectors/valid.tsv rows 1..4096", ns, snow), nil
}

var theCorpus *benchCorpus

// corpus returns the bench corpus: the vectors file when present, otherwise
// its regeneration — unless BRD14_REQUIRE_VECTORS=1 insists on the file.
func corpus(tb testing.TB) *benchCorpus {
	tb.Helper()
	if theCorpus != nil {
		return theCorpus
	}
	c, err := fileCorpus()
	switch {
	case errors.Is(err, fs.ErrNotExist) && os.Getenv("BRD14_REQUIRE_VECTORS") == "1":
		tb.Fatalf("BRD14_REQUIRE_VECTORS=1 but %s is absent: %v", vectorsDir, err)
	case errors.Is(err, fs.ErrNotExist):
		c = generatedCorpus()
	case err != nil:
		tb.Fatal(err)
	}
	theCorpus = c
	return c
}

// TestBenchCorpusMatchesVectors: the regenerated corpus IS the file's first
// 4096 rows, so a bench run without the repository measures the same inputs.
func TestBenchCorpusMatchesVectors(t *testing.T) {
	rows := vectorRows(t, "valid.tsv", 8)
	gen := generatedCorpus()
	for i := 0; i < corpusN; i++ {
		got := strings.Join([]string{gen.ns[i], strconv.FormatUint(gen.snow[i], 10), gen.ids[i*Len : (i+1)*Len]}, "\t")
		if want := strings.Join(rows[i][:3], "\t"); got != want {
			t.Fatalf("corpus row %d: regenerated %q, vectors/valid.tsv has %q", i+1, got, want)
		}
	}
}
