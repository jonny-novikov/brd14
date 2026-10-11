package brd14

import (
	"os"
	"strconv"
	"sync/atomic"
	"time"
)

const (
	seqBits  = 12
	nodeBits = 10
	nodeMask = (1 << nodeBits) - 1
	seqMask  = (1 << seqBits) - 1
)

// Generator is a lock-free snowflake minter mirroring EchoData.Snowflake. The
// single atomic cell holds the monotonic part ts<<12|seq; each mint
// CAS-advances max(now, last+1), so ids are strictly increasing even within one
// millisecond (sequence increments) or across a backward clock step (the
// logical clock keeps minting). Layout on the wire: ts(41)<<22 | node(10)<<12 |
// seq(12), epoch 2024-01-01Z.
type Generator struct {
	cell atomic.Int64
	node uint64
}

// NewGenerator builds a minter for the given node id (masked to 0..1023).
func NewGenerator(node uint64) *Generator {
	g := &Generator{node: node & nodeMask}
	g.cell.Store(nowPart())
	return g
}

// NodeFrom derives a 10-bit node id: FNV-32a over the host bytes (possibly
// empty) followed by the ASCII-decimal pid, masked to 10 bits — the contract's
// node_from, which every implementation reproduces and vectors/node.tsv pins.
// The pid is mixed UNCONDITIONALLY, so two processes on one host derive
// DIFFERENT node ids except when the masked hash collides — a residual of
// ~1/1024 per same-host process pair, load-independent and never zero.
// Collision is made improbable and budgetable, not impossible. An empty host
// hashes the ASCII-decimal pid alone, which reproduces the pre-fix fallback
// bytes exactly.
//
// The hash is written out rather than taken from hash/fnv: that package hands
// back its state behind an interface and wants the host as a []byte, which is
// two allocations for a dozen lines of arithmetic. This form allocates nothing
// and is the contract's definition verbatim; TestNodeFromMatchesHashFNV holds
// it to the standard library's implementation.
func NodeFrom(host string, pid int) uint64 {
	const offset32, prime32 = 2166136261, 16777619 // the FNV-1a 32-bit parameters
	h := uint32(offset32)
	for i := 0; i < len(host); i++ {
		h ^= uint32(host[i])
		h *= prime32
	}
	var dec [20]byte // len("-9223372036854775808"): any int's decimal fits
	for _, c := range strconv.AppendInt(dec[:0], int64(pid), 10) {
		h ^= uint32(c)
		h *= prime32
	}
	return uint64(h) & nodeMask
}

// DefaultNode derives a coordination-free node id (0..1023) from the hostname
// AND the pid — no registry, mint on any host. Distinct per process on one
// host up to the residual NodeFrom documents. A hostname error falls back to
// the empty host, which NodeFrom hashes as the pid alone.
func DefaultNode() uint64 {
	name, err := os.Hostname()
	if err != nil {
		name = ""
	}
	return NodeFrom(name, os.Getpid())
}

// Next mints the next monotonic snowflake.
func (g *Generator) Next() uint64 {
	v := uint64(g.advance(nowPart()))
	ts := v >> seqBits
	seq := v & seqMask
	return ts<<22 | g.node<<seqBits | seq
}

// NextBranded mints the next snowflake and brands it under ns in one call.
// The returned string is its only allocation. Like every refusal here, a
// malformed ns yields ErrNamespace; the snowflake drawn for it is simply
// skipped, which a generator's contract allows (strictly increasing, not
// gap-free).
func (g *Generator) NextBranded(ns string) (string, error) {
	return Encode(ns, g.Next())
}

// AppendNextBranded is NextBranded appending to a caller-owned buffer, under
// AppendEncode's rules: a refusal returns dst unchanged, and with Len bytes of
// spare capacity nothing is allocated — the whole mint, clock read and CAS
// included, runs without touching the heap.
func (g *Generator) AppendNextBranded(dst []byte, ns string) ([]byte, error) {
	return AppendEncode(dst, ns, g.Next())
}

func (g *Generator) advance(cand int64) int64 {
	for {
		last := g.cell.Load()
		next := cand
		if last+1 > next {
			next = last + 1
		}
		if g.cell.CompareAndSwap(last, next) {
			return next
		}
	}
}

func nowPart() int64 {
	return (time.Now().UnixMilli() - EpochMs) << seqBits
}

// NodeOf decodes the node field of a snowflake: (snow >> 12) & 1023.
func NodeOf(snow uint64) uint64 { return (snow >> seqBits) & nodeMask }

// SeqOf decodes the sequence field of a snowflake: snow & 4095.
func SeqOf(snow uint64) uint64 { return snow & seqMask }
