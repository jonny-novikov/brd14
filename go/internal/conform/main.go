// Command conform is the Go reference's parity shim: it speaks the request /
// response protocol of docs/contract.md ("Parity shim protocol") on stdin and
// stdout, so tools/parity.py can diff every answer this package gives against
// the oracle's, byte for byte.
//
//	go build -o ../build/shims/go-conform ./internal/conform   # make conform
//
// The shim is deliberately thin: each request is answered by exactly one call
// into the public API a consumer would make — AppendEncode for E (with the
// namespace bytes passed through raw, however malformed), ParseBytes for D,
// Hash32, UnixMs, NodeOf/SeqOf and NodeFrom for the rest, and for G (the virtual
// clock extension) a generator built by NewGeneratorWithClock, driven by Next and
// Observe — and every refusal is named by errors.Is against the typed causes, the
// way a consumer would ask.
// Nothing here re-implements the contract, so a mismatch in the parity run is a
// finding about the package, not about the harness.
//
// A malformed REQUEST is not a contract answer, so it is never answered: the
// shim reports it on stderr and exits 2, which the driver records as a failed
// run instead of a silent mismatch.
package main

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"errors"
	"fmt"
	"hash/fnv"
	"io"
	"os"
	"strconv"

	brd14 "github.com/jonny-novikov/brd14/go"
)

// hello is the first output line: implementation, variant, supported ops.
const hello = "HELLO go reference EDHUFNG\n"

func main() {
	in := bufio.NewReaderSize(os.Stdin, 1<<20)
	out := bufio.NewWriterSize(os.Stdout, 1<<20)
	err := serve(in, out)
	if ferr := out.Flush(); err == nil {
		err = ferr
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "go-conform:", err)
		os.Exit(2)
	}
}

// serve answers requests until EOF. Output is buffered in 1 MiB blocks and
// flushed whenever the input buffer runs dry — so a file-fed run (the parity
// driver's mode) flushes once per megabyte, and an interactive peer that waits
// for each answer before sending the next request still gets it.
func serve(in *bufio.Reader, out *bufio.Writer) error {
	if _, err := out.WriteString(hello); err != nil {
		return err
	}
	var s shim
	for n := 1; ; n++ {
		if in.Buffered() == 0 {
			if err := out.Flush(); err != nil {
				return err
			}
		}
		line, rerr := in.ReadSlice('\n')
		switch {
		case rerr == bufio.ErrBufferFull:
			return fmt.Errorf("line %d: longer than %d bytes", n, in.Size())
		case rerr != nil && rerr != io.EOF:
			return rerr
		}
		line = bytes.TrimRight(line, "\r\n")
		if len(line) > 0 {
			resp, err := s.answer(line)
			if err != nil {
				return fmt.Errorf("line %d: %v: %q", n, err, line)
			}
			if _, err := out.Write(resp); err != nil {
				return err
			}
		}
		if rerr == io.EOF {
			return nil
		}
	}
}

// shim holds the scratch buffers reused across requests.
type shim struct {
	resp []byte
	arg  [3][]byte
	raw  []byte // the decoded hex argument
}

// answer returns the response line (newline included) for one request line.
// The returned slice is valid until the next call.
func (s *shim) answer(line []byte) ([]byte, error) {
	op, args, err := s.split(line)
	if err != nil {
		return nil, err
	}
	r := append(s.resp[:0], "OK "...)
	switch op {
	case 'E': // E <ns_hex> <snow>
		if err := want(args, 2); err != nil {
			return nil, err
		}
		ns, err := s.unhex(args[0])
		if err != nil {
			return nil, err
		}
		snow, err := parseUint(args[1])
		if err != nil {
			return nil, err
		}
		if r, err = brd14.AppendEncode(r, string(ns), snow); err != nil {
			if r, err = refuse(r[:0], err); err != nil {
				return nil, err
			}
		}
	case 'D': // D <id_hex>
		if err := want(args, 1); err != nil {
			return nil, err
		}
		id, err := s.unhex(args[0])
		if err != nil {
			return nil, err
		}
		ns, snow, perr := brd14.ParseBytes(id)
		if perr != nil {
			if r, err = refuse(r[:0], perr); err != nil {
				return nil, err
			}
			break
		}
		r = append(r, ns[:]...)
		r = append(r, ' ')
		r = strconv.AppendUint(r, snow, 10)
	case 'H': // H <k>, k in [0, 2^64)
		if err := want(args, 1); err != nil {
			return nil, err
		}
		k, err := parseUint(args[0])
		if err != nil {
			return nil, err
		}
		r = strconv.AppendUint(r, uint64(brd14.Hash32(k)), 10)
	case 'U': // U <snow>
		if err := want(args, 1); err != nil {
			return nil, err
		}
		snow, err := parseUint(args[0])
		if err != nil {
			return nil, err
		}
		r = strconv.AppendInt(r, brd14.UnixMs(snow), 10)
	case 'F': // F <snow> -> ts node seq
		if err := want(args, 1); err != nil {
			return nil, err
		}
		snow, err := parseUint(args[0])
		if err != nil {
			return nil, err
		}
		r = strconv.AppendUint(r, snow>>22, 10)
		r = append(r, ' ')
		r = strconv.AppendUint(r, brd14.NodeOf(snow), 10)
		r = append(r, ' ')
		r = strconv.AppendUint(r, brd14.SeqOf(snow), 10)
	case 'N': // N <host_hex> <pid>
		if err := want(args, 2); err != nil {
			return nil, err
		}
		host, err := s.unhex(args[0])
		if err != nil {
			return nil, err
		}
		pid, err := strconv.Atoi(string(args[1]))
		if err != nil {
			return nil, err
		}
		r = strconv.AppendUint(r, brd14.NodeFrom(string(host), pid), 10)
	case 'G': // G <node> <start_ms> <program> (the virtual clock extension)
		if err := want(args, 3); err != nil {
			return nil, err
		}
		node, err := parseUint(args[0])
		if err != nil {
			return nil, err
		}
		start, err := strconv.ParseInt(string(args[1]), 10, 64)
		if err != nil {
			return nil, err
		}
		if r, err = replay(r, node, start, args[2]); err != nil {
			return nil, err
		}
	default:
		return nil, fmt.Errorf("unknown request %q", op)
	}
	s.resp = append(r, '\n')
	return s.resp, nil
}

// replay runs a virtual-clock program (docs/contract.md, "Virtual clock") on a
// generator over an injected clock and appends "<count> <first> <last> <digest>
// <verdicts> <virtual_ms>": t<ms> sets the clock, m<k> mints k ids, o<snow>~<ahead>
// observes. The digest is FNV-1a-64 over the decimal ids joined by commas.
func replay(r []byte, node uint64, start int64, program []byte) ([]byte, error) {
	now := start
	g := brd14.NewGeneratorWithClock(node, func() int64 { return now })
	h := fnv.New64a()
	var num, verdicts []byte
	var first, last uint64
	count := 0
	for _, tok := range bytes.Split(program, []byte{','}) {
		if len(tok) < 2 {
			return nil, fmt.Errorf("program token %q", tok)
		}
		switch tok[0] {
		case 't':
			ms, err := strconv.ParseInt(string(tok[1:]), 10, 64)
			if err != nil {
				return nil, err
			}
			now = ms
		case 'm':
			k, err := strconv.Atoi(string(tok[1:]))
			if err != nil || k < 0 {
				return nil, fmt.Errorf("program token %q", tok)
			}
			for i := 0; i < k; i++ {
				snow := g.Next()
				if count == 0 {
					first = snow
				} else {
					h.Write([]byte{','})
				}
				last = snow
				count++
				num = strconv.AppendUint(num[:0], snow, 10)
				h.Write(num)
			}
		case 'o':
			snowS, aheadS, ok := bytes.Cut(tok[1:], []byte{'~'})
			if !ok {
				return nil, fmt.Errorf("program token %q", tok)
			}
			snow, err := parseUint(snowS)
			if err != nil {
				return nil, err
			}
			ahead, err := strconv.ParseInt(string(aheadS), 10, 64)
			if err != nil {
				return nil, err
			}
			applied, err := g.Observe(snow, ahead)
			if err != nil { // a program observes ids below 2^63 only: outside the protocol
				return nil, fmt.Errorf("program token %q: %v", tok, err)
			}
			if applied {
				verdicts = append(verdicts, '1')
			} else {
				verdicts = append(verdicts, '0')
			}
		default:
			return nil, fmt.Errorf("program token %q", tok)
		}
	}
	r = strconv.AppendInt(r, int64(count), 10)
	if count == 0 {
		r = append(r, " - -"...)
	} else {
		r = append(r, ' ')
		r = strconv.AppendUint(r, first, 10)
		r = append(r, ' ')
		r = strconv.AppendUint(r, last, 10)
	}
	r = fmt.Appendf(r, " %016x ", h.Sum64())
	if len(verdicts) == 0 {
		verdicts = append(verdicts, '-')
	}
	r = append(r, verdicts...)
	r = append(r, ' ')
	return strconv.AppendInt(r, g.VirtualUnixMs(), 10), nil
}

// split cuts "<op> <arg> [<arg> [<arg>]]" on single spaces. The op is one byte;
// at most three arguments are kept (want rejects a count the op does not take).
func (s *shim) split(line []byte) (op byte, args [][]byte, err error) {
	if len(line) < 1 || len(line) > 1 && line[1] != ' ' {
		return 0, nil, errors.New("request is not '<op> <args>'")
	}
	args = s.arg[:0]
	rest := line[1:]
	for len(rest) > 0 {
		rest = rest[1:] // the separating space
		i := bytes.IndexByte(rest, ' ')
		if i < 0 {
			i = len(rest)
		}
		if i == 0 {
			return 0, nil, errors.New("empty argument")
		}
		if len(args) == len(s.arg) {
			return 0, nil, errors.New("too many arguments")
		}
		args = append(args, rest[:i])
		rest = rest[i:]
	}
	return line[0], args, nil
}

func want(args [][]byte, n int) error {
	if len(args) != n {
		return fmt.Errorf("%d arguments, want %d", len(args), n)
	}
	return nil
}

// unhex decodes the protocol's byte notation ("-" is empty) into the shim's
// scratch buffer.
func (s *shim) unhex(h []byte) ([]byte, error) {
	if len(h) == 1 && h[0] == '-' {
		return s.raw[:0], nil
	}
	if len(h)%2 != 0 {
		return nil, fmt.Errorf("odd-length hex %q", h)
	}
	if cap(s.raw) < len(h)/2 {
		s.raw = make([]byte, len(h)/2)
	}
	s.raw = s.raw[:len(h)/2]
	if _, err := hex.Decode(s.raw, h); err != nil {
		return nil, err
	}
	return s.raw, nil
}

func parseUint(b []byte) (uint64, error) {
	return strconv.ParseUint(string(b), 10, 64)
}

// refuse writes "ERR <CLASS>" for a refusal, naming the class by errors.Is
// against the typed causes in the contract's code order. An error that is none
// of them is a defect in the package, reported rather than guessed at.
func refuse(r []byte, err error) ([]byte, error) {
	var class string
	switch {
	case errors.Is(err, brd14.ErrLength):
		class = "LENGTH"
	case errors.Is(err, brd14.ErrNamespace):
		class = "NAMESPACE"
	case errors.Is(err, brd14.ErrCharset):
		class = "CHARSET"
	case errors.Is(err, brd14.ErrRange):
		class = "RANGE"
	default:
		return nil, fmt.Errorf("refusal %v is not one of the typed causes", err)
	}
	return append(append(r, "ERR "...), class...), nil
}
