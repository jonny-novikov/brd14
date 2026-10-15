// Command vclocknode hosts brd14 generators on virtual clocks behind a line protocol, so a
// test in another runtime (python/tests/test_virtual_clock.py) can run a fleet that mixes
// its own generators with Go ones and exchange real ids across the process boundary.
//
// One request per line on stdin, one response line on stdout:
//
//	new <g> <node> <unix_ms>   create generator g with its clock at unix_ms   → ok
//	t <g> <unix_ms>            set g's clock                                  → ok
//	m <g>                      mint                                           → <snowflake>
//	o <g> <snow> <max_ahead>   Observe                                        → 1 | 0 | ERR RANGE
//	v <g>                      VirtualUnixMs                                  → <unix_ms>
//
// A malformed request is fatal (exit 2): the driver is a test, and a silent answer would hide
// its bug.
package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"

	brd14 "github.com/jonny-novikov/brd14/go"
)

type node struct {
	gen *brd14.Generator
	ms  int64
}

func main() {
	nodes := map[string]*node{}
	in := bufio.NewScanner(os.Stdin)
	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()
	fail := func(format string, a ...any) {
		out.Flush()
		fmt.Fprintf(os.Stderr, "vclocknode: "+format+"\n", a...)
		os.Exit(2)
	}
	num := func(s string) int64 {
		v, err := strconv.ParseInt(s, 10, 64)
		if err != nil {
			fail("not a number: %q", s)
		}
		return v
	}
	for in.Scan() {
		f := strings.Fields(in.Text())
		if len(f) < 2 {
			fail("short request %q", in.Text())
		}
		if f[0] == "new" {
			if len(f) != 4 {
				fail("new <g> <node> <unix_ms>: %q", in.Text())
			}
			n := &node{ms: num(f[3])}
			n.gen = brd14.NewGeneratorWithClock(uint64(num(f[2])), func() int64 { return n.ms })
			nodes[f[1]] = n
			fmt.Fprintln(out, "ok")
			out.Flush()
			continue
		}
		n, ok := nodes[f[1]]
		if !ok {
			fail("no generator %q", f[1])
		}
		switch {
		case f[0] == "t" && len(f) == 3:
			n.ms = num(f[2])
			fmt.Fprintln(out, "ok")
		case f[0] == "m" && len(f) == 2:
			fmt.Fprintln(out, n.gen.Next())
		case f[0] == "o" && len(f) == 4:
			snow, err := strconv.ParseUint(f[2], 10, 64)
			if err != nil {
				fail("not a snowflake: %q", f[2])
			}
			applied, err := n.gen.Observe(snow, num(f[3]))
			switch {
			case err != nil:
				fmt.Fprintln(out, "ERR RANGE")
			case applied:
				fmt.Fprintln(out, "1")
			default:
				fmt.Fprintln(out, "0")
			}
		case f[0] == "v" && len(f) == 2:
			fmt.Fprintln(out, n.gen.VirtualUnixMs())
		default:
			fail("unknown request %q", in.Text())
		}
		out.Flush()
	}
}
