package brd14

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"
)

// ── §5.3 the node derivation: pinned mapping + live wiring ───────────────────

// nodeChildEnv makes a re-exec of this test binary report DefaultNode() and
// exit. The wiring check needs FRESH processes with REAL distinct pids: the
// pure seam's vectors prove the mapping, never that DefaultNode feeds it the
// live pid, and a revert that bypasses the seam rides green vectors otherwise.
const nodeChildEnv = "BRANDEDID_NODE_CHILD"

// TestNodeFromGoldenVectors pins the derivation (INV-NODE-PID). The values were
// computed independently of this implementation (FNV-32a over host-bytes ++
// ASCII-decimal pid, masked to 10 bits) and are frozen: a silent re-derivation
// reds here.
//
// Two rows carry extra weight:
//   - ("hosta",100)=585 is the GOLDEN. The hostname-only mutant — the pre-fix
//     derivation, which drops the pid write — yields 266 at this input, so a
//     dropped pid write reds this row.
//   - ("",100)=156 is the FALLBACK CONTINUITY row: an empty host makes the hash
//     input the ASCII-decimal pid alone, byte-for-byte what the pre-fix
//     hostname-error branch hashed. Continuity is exact, not approximate.
func TestNodeFromGoldenVectors(t *testing.T) {
	for _, c := range []struct {
		host string
		pid  int
		want uint64
	}{
		{"hosta", 100, 585}, // golden; hostname-only mutant yields 266
		{"hosta", 101, 182},
		{"hosta", 4242, 290},
		{"", 100, 156}, // == the pre-fix fallback mapping (continuity)
		{"", 101, 559},
	} {
		if got := nodeFrom(c.host, c.pid); got != c.want {
			t.Errorf("nodeFrom(%q,%d) = %d, want %d", c.host, c.pid, got, c.want)
		}
	}
}

// TestNodeFromMixesPidUnconditionally states the property the vectors witness:
// on ONE host, distinct pids map to distinct node ids (the pid is not consulted
// only on a hostname error). The bound is honest — distinctness holds up to the
// ~1/1024 masked-hash collision — so the claim is checked over a pid sweep and
// asserted as a distinctness RATE, never as impossibility.
func TestNodeFromMixesPidUnconditionally(t *testing.T) {
	const host = "hosta"
	seen := make(map[uint64]int, 1024)
	const trials = 512
	for pid := 1; pid <= trials; pid++ {
		seen[nodeFrom(host, pid)]++
	}
	if len(seen) < 2 {
		t.Fatalf("nodeFrom collapsed %d pids onto %d node id(s) — the pid is not mixed", trials, len(seen))
	}
	// 512 draws over 1024 buckets: the birthday expectation is ~394 distinct.
	// A floor of 300 reds a derivation that mixes the pid only weakly while
	// leaving ample slack for the design residual.
	if len(seen) < 300 {
		t.Errorf("nodeFrom spread: %d distinct node ids over %d pids, want >= 300", len(seen), trials)
	}
	if nodeFrom(host, 100) == nodeFrom(host, 101) {
		t.Errorf("nodeFrom(%q,100) == nodeFrom(%q,101) — pid does not reach the hash", host, host)
	}
}

// TestNodeFromHostSeparation holds the cross-host distinctness the pre-fix
// derivation provided and this one must not lose: one pid on different hosts
// still derives different node ids (again up to the 1/1024 residual).
func TestNodeFromHostSeparation(t *testing.T) {
	const pid = 4242
	a, b, c := nodeFrom("hosta", pid), nodeFrom("hostb", pid), nodeFrom("", pid)
	if a == b && b == c {
		t.Fatalf("hosta/hostb/empty all derive node %d at pid %d — the host bytes do not reach the hash", a, pid)
	}
}

// TestDefaultNodeLiveWiring is the three-process check (INV-WIRING-LIVE): the
// parent plus two re-exec children each report DefaultNode(), and NOT all three
// may be equal. A revert to the hostname-only derivation reds this with
// certainty (all three share one host, so all three collapse to one id); the
// false-red probability is the chance both children collide with the parent,
// ~(1/1024)^2 ~ 1e-6.
func TestDefaultNodeLiveWiring(t *testing.T) {
	if os.Getenv(nodeChildEnv) != "" {
		fmt.Printf("NODE=%d\n", DefaultNode())
		return
	}
	nodes := []uint64{DefaultNode()}
	for i := 0; i < 2; i++ {
		nodes = append(nodes, reExecNode(t, i))
	}
	if nodes[0] == nodes[1] && nodes[1] == nodes[2] {
		t.Fatalf("all three processes derived node %d — DefaultNode does not mix the LIVE pid "+
			"(false-red ~1e-6; suspect a revert to the hostname-only derivation)", nodes[0])
	}
	t.Logf("three-process node ids: parent=%d child0=%d child1=%d", nodes[0], nodes[1], nodes[2])
}

// reExecNode runs this test binary again with nodeChildEnv set and reads the
// child's DefaultNode() off stdout. Every failure path is LOUD: an unusable
// re-exec is a broken check, never a skipped one.
func reExecNode(t *testing.T, i int) uint64 {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run", "^TestDefaultNodeLiveWiring$")
	cmd.Env = append(os.Environ(), nodeChildEnv+"=1")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("child %d re-exec failed: %v\n%s", i, err, out)
	}
	for _, line := range strings.Split(string(out), "\n") {
		rest, ok := strings.CutPrefix(strings.TrimSpace(line), "NODE=")
		if !ok {
			continue
		}
		n, perr := strconv.ParseUint(strings.TrimSpace(rest), 10, 64)
		if perr != nil {
			t.Fatalf("child %d node parse from %q: %v", i, rest, perr)
		}
		return n
	}
	t.Fatalf("child %d printed no NODE= line:\n%s", i, out)
	return 0
}

// ── §5.2 T-5 the snowflake layout + per-generator monotonicity ───────────────

// TestGeneratorLayout pins the wire layout (INV-WIRE-SHAPE) and the CAS cell's
// strict per-process ordering: for a generator on node n, every mint carries
// node n, a sequence inside the 12-bit field, and a strictly greater snowflake
// than the mint before it — inside one millisecond (sequence increments) as
// well as across.
func TestGeneratorLayout(t *testing.T) {
	const node = 613
	g := NewGenerator(node)
	var prev uint64
	for i := 0; i < 10000; i++ {
		snow := g.Next()
		if got := NodeOf(snow); got != node {
			t.Fatalf("mint %d: node field = %d, want %d", i, got, node)
		}
		if snow <= prev {
			t.Fatalf("mint %d: snowflake %d not strictly greater than %d", i, snow, prev)
		}
		// The field partition closes: ts | node | seq reconstructs the value
		// with no gap and no overlap. A minter that shifted a field (node<<13
		// rather than node<<12) reds here even where NodeOf still reads.
		// SeqOf/NodeOf mask by construction, so their RANGE is not a violable
		// claim and is not asserted; the partition is.
		if got := snow>>22<<22 | NodeOf(snow)<<seqBits | SeqOf(snow); got != snow {
			t.Fatalf("mint %d: ts|node|seq reconstructs %d, want %d", i, got, snow)
		}
		prev = snow
	}
	// The ts field carries the real mint instant against the contract epoch: a
	// wrong shift or a wrong epoch offset reds here.
	if ms := UnixMs(g.Next()); ms < time.Now().UnixMilli()-60_000 || ms > time.Now().UnixMilli()+60_000 {
		t.Errorf("minted ts %d is not within a minute of now — epoch or ts shift is wrong", ms)
	}
	// The node argument is masked into the 10-bit field, never overflowed into
	// the timestamp.
	if got := NodeOf(NewGenerator(1<<nodeBits | 5).Next()); got != 5 {
		t.Errorf("NewGenerator node masking: got %d, want 5", got)
	}
}

// TestEpochBoundaries pins UnixMs/Time/MinFor at the epoch instants (T-5): the
// snowflake 0 is the epoch itself, and MinFor is the half-open lower bound used
// by time-range scans.
func TestEpochBoundaries(t *testing.T) {
	if got := UnixMs(0); got != EpochMs {
		t.Errorf("UnixMs(0) = %d, want %d", got, EpochMs)
	}
	if got := UnixMs(1 << 22); got != EpochMs+1 {
		t.Errorf("UnixMs(1<<22) = %d, want %d", got, EpochMs+1)
	}
	// The node and seq fields never leak into the extracted instant.
	if got := UnixMs(1<<22 | 1023<<12 | 4095); got != EpochMs+1 {
		t.Errorf("UnixMs with node+seq populated = %d, want %d", got, EpochMs+1)
	}
	epoch := time.UnixMilli(EpochMs)
	if got := MinFor(epoch); got != 0 {
		t.Errorf("MinFor(epoch) = %d, want 0", got)
	}
	if got := MinFor(epoch.Add(time.Millisecond)); got != 1<<22 {
		t.Errorf("MinFor(epoch+1ms) = %d, want %d", got, uint64(1<<22))
	}
	if got := Time(1 << 22); !got.Equal(time.UnixMilli(EpochMs + 1)) {
		t.Errorf("Time(1<<22) = %v, want %v", got, time.UnixMilli(EpochMs+1))
	}
}
