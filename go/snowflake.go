package brd14

import (
	"hash/fnv"
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

// nodeFrom derives the 10-bit node id: FNV-32a over host-bytes (possibly
// empty) followed by the ASCII-decimal pid, masked to nodeMask. The pid is
// mixed UNCONDITIONALLY, so two processes on one host derive DIFFERENT node
// ids except when the masked hash collides — a residual of ~1/1024 per
// same-host process pair, load-independent and never zero. Collision is made
// improbable and budgetable, not impossible. An empty host reproduces the
// pre-fix fallback bytes exactly (the ASCII-decimal pid alone).
func nodeFrom(host string, pid int) uint64 {
	h := fnv.New32a()
	if host != "" {
		_, _ = h.Write([]byte(host))
	}
	_, _ = h.Write([]byte(strconv.Itoa(pid)))
	return uint64(h.Sum32()) & nodeMask
}

// DefaultNode derives a coordination-free node id (0..1023) from the hostname
// AND the pid — no registry, mint on any host. Distinct per process on one
// host up to the residual nodeFrom documents.
func DefaultNode() uint64 {
	name, err := os.Hostname()
	if err != nil {
		name = ""
	}
	return nodeFrom(name, os.Getpid())
}

// Next mints the next monotonic snowflake.
func (g *Generator) Next() uint64 {
	v := uint64(g.advance(nowPart()))
	ts := v >> seqBits
	seq := v & seqMask
	return ts<<22 | g.node<<seqBits | seq
}

// NextBranded mints the next snowflake and brands it under ns in one call.
func (g *Generator) NextBranded(ns string) (string, error) {
	return Encode(ns, g.Next())
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

// NodeOf and SeqOf decode the node and sequence fields of a snowflake.
func NodeOf(snow uint64) uint64 { return (snow >> seqBits) & nodeMask }
func SeqOf(snow uint64) uint64  { return snow & seqMask }
