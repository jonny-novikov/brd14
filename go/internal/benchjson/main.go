// Command benchjson reduces `go test -bench -benchmem -count N` output to the
// repository's shared bench result schema (bench/README.md): one JSON document
// per (implementation, variant, runtime), one entry per operation, with the
// median ns/op over the N samples, its median absolute deviation, and the
// allocation figures -benchmem reports.
//
//	go test -run '^$' -bench . -benchmem -count 10 > bench.out
//	go run ./internal/benchjson -runtime go1.26.9 -pinned -o ../bench/results/go-reference-go1.26.9.json < bench.out
//
// It is deliberately a reducer, not a runner: the samples come from the
// standard tool, unmodified, so the raw output stays readable by benchstat and
// the JSON can always be regenerated from it. Standard library only.
//
// Operation names are the benchmark names with the "Benchmark" prefix and the
// GOMAXPROCS suffix removed, converted to snake_case: BenchmarkEncodeAppend-4
// becomes encode_append, BenchmarkHash32 becomes hash32.
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"os"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"unicode"
)

// Doc is the result document, field for field the schema in bench/README.md.
type Doc struct {
	Impl    string   `json:"impl"`
	Variant string   `json:"variant"`
	Runtime string   `json:"runtime"`
	Machine string   `json:"machine"`
	Pinned  bool     `json:"pinned"`
	Corpus  string   `json:"corpus"`
	Results []Result `json:"results"`
}

// Result is one operation. CV is the coefficient of variation of the samples
// (stddev / mean), which the protocol asks every report to state; above 0.05
// the row is noisy.
type Result struct {
	Op          string  `json:"op"`
	NsPerOp     float64 `json:"ns_per_op"`
	MadNs       float64 `json:"mad_ns"`
	Samples     int     `json:"samples"`
	CV          float64 `json:"cv"`
	AllocsPerOp int64   `json:"allocs_per_op"`
	BytesPerOp  int64   `json:"bytes_per_op"`
}

// series collects one benchmark's samples in input order.
type series struct {
	op     string
	ns     []float64
	allocs []int64
	bytes  []int64
}

func main() {
	impl := flag.String("impl", "go", "implementation name")
	variant := flag.String("variant", "reference", "variant name")
	rt := flag.String("runtime", runtime.Version(), "runtime label, e.g. go1.26.9")
	pinned := flag.Bool("pinned", false, "the samples were taken pinned to one core")
	corpus := flag.String("corpus", "vectors/valid.tsv rows 1..4096", "corpus label")
	out := flag.String("o", "", "output file (default stdout)")
	flag.Parse()

	doc, err := reduce(os.Stdin, Doc{Impl: *impl, Variant: *variant, Runtime: *rt, Pinned: *pinned, Corpus: *corpus})
	if err != nil {
		fail(err)
	}
	if doc.Machine == "" {
		doc.Machine = cpuModel()
	}
	data, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		fail(err)
	}
	data = append(data, '\n')
	if *out == "" {
		_, err = os.Stdout.Write(data)
	} else {
		err = os.WriteFile(*out, data, 0o644)
	}
	if err != nil {
		fail(err)
	}
	summarize(os.Stderr, doc)
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "benchjson:", err)
	os.Exit(1)
}

// reduce parses benchmark output into doc.Results, one per operation in order
// of first appearance, and takes the machine from the "cpu:" header line.
func reduce(r io.Reader, doc Doc) (Doc, error) {
	var order []*series
	byName := map[string]*series{}
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		line := sc.Text()
		if cpu, ok := strings.CutPrefix(line, "cpu: "); ok {
			doc.Machine = strings.TrimSpace(cpu)
			continue
		}
		f := strings.Fields(line)
		if len(f) < 4 || !strings.HasPrefix(f[0], "Benchmark") || f[3] != "ns/op" {
			continue
		}
		ns, err := strconv.ParseFloat(f[2], 64)
		if err != nil {
			return doc, fmt.Errorf("%q: %v", line, err)
		}
		op := opName(f[0])
		s := byName[op]
		if s == nil {
			s = &series{op: op}
			byName[op] = s
			order = append(order, s)
		}
		s.ns = append(s.ns, ns)
		for i := 4; i+1 < len(f); i += 2 {
			v, err := strconv.ParseInt(f[i], 10, 64)
			if err != nil {
				continue // a custom float metric; not part of the schema
			}
			switch f[i+1] {
			case "allocs/op":
				s.allocs = append(s.allocs, v)
			case "B/op":
				s.bytes = append(s.bytes, v)
			}
		}
	}
	if err := sc.Err(); err != nil {
		return doc, err
	}
	if len(order) == 0 {
		return doc, errors.New("no benchmark lines on stdin")
	}
	for _, s := range order {
		med := median(s.ns)
		dev := make([]float64, len(s.ns))
		for i, x := range s.ns {
			dev[i] = math.Abs(x - med)
		}
		doc.Results = append(doc.Results, Result{
			Op:          s.op,
			NsPerOp:     round(med, 4),
			MadNs:       round(median(dev), 4),
			Samples:     len(s.ns),
			CV:          round(cv(s.ns), 4),
			AllocsPerOp: maxOr(s.allocs, -1),
			BytesPerOp:  maxOr(s.bytes, -1),
		})
	}
	return doc, nil
}

// opName turns "BenchmarkEncodeAppend-4" into "encode_append".
func opName(bench string) string {
	name := strings.TrimPrefix(bench, "Benchmark")
	if i := strings.LastIndexByte(name, '-'); i > 0 {
		if _, err := strconv.Atoi(name[i+1:]); err == nil {
			name = name[:i]
		}
	}
	var b strings.Builder
	rs := []rune(name)
	for i, r := range rs {
		if unicode.IsUpper(r) {
			if i > 0 && (unicode.IsLower(rs[i-1]) || unicode.IsDigit(rs[i-1])) {
				b.WriteByte('_')
			}
			r = unicode.ToLower(r)
		}
		b.WriteRune(r)
	}
	return b.String()
}

func median(xs []float64) float64 {
	s := append([]float64(nil), xs...)
	sort.Float64s(s)
	n := len(s)
	if n%2 == 1 {
		return s[n/2]
	}
	return (s[n/2-1] + s[n/2]) / 2
}

// cv is the sample coefficient of variation: stddev (n-1) over the mean.
func cv(xs []float64) float64 {
	if len(xs) < 2 {
		return 0
	}
	var sum float64
	for _, x := range xs {
		sum += x
	}
	mean := sum / float64(len(xs))
	var ss float64
	for _, x := range xs {
		ss += (x - mean) * (x - mean)
	}
	return math.Sqrt(ss/float64(len(xs)-1)) / mean
}

// maxOr reports the largest value, or def when -benchmem reported none. The
// maximum, not the median: an allocation claim should hold for every sample.
func maxOr(xs []int64, def int64) int64 {
	if len(xs) == 0 {
		return def
	}
	m := xs[0]
	for _, x := range xs[1:] {
		if x > m {
			m = x
		}
	}
	return m
}

func round(x float64, places int) float64 {
	p := math.Pow(10, float64(places))
	return math.Round(x*p) / p
}

// cpuModel is the fallback machine label when the output carried no "cpu:"
// line: lscpu's "Model name", read from /proc/cpuinfo.
func cpuModel() string {
	data, err := os.ReadFile("/proc/cpuinfo")
	if err != nil {
		return runtime.GOARCH
	}
	for _, line := range strings.Split(string(data), "\n") {
		if k, v, ok := strings.Cut(line, ":"); ok && strings.TrimSpace(k) == "model name" {
			return strings.TrimSpace(v)
		}
	}
	return runtime.GOARCH
}

// summarize prints the table a human reads after `make bench`.
func summarize(w io.Writer, doc Doc) {
	fmt.Fprintf(w, "%s/%s %s on %s (pinned=%v)\n", doc.Impl, doc.Variant, doc.Runtime, doc.Machine, doc.Pinned)
	fmt.Fprintf(w, "%-14s %10s %8s %7s %7s %7s\n", "op", "ns/op", "mad", "cv", "allocs", "B/op")
	for _, r := range doc.Results {
		noisy := ""
		if r.CV > 0.05 {
			noisy = "  noisy"
		}
		fmt.Fprintf(w, "%-14s %10.2f %8.2f %6.1f%% %7d %7d%s\n", r.Op, r.NsPerOp, r.MadNs, 100*r.CV, r.AllocsPerOp, r.BytesPerOp, noisy)
	}
}
