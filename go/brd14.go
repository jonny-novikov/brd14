// brd14.go: the codec — encode, parse, and the derived reads over a branded
// snowflake. The package doc is in doc.go; the minter is in snowflake.go and
// the consumer-side namespace plug is in minter.go.
//
// Every literal here is contract, not implementation detail: the epoch, the
// alphabet's ASCII ordering, the fixed width, and the maxPayload guard are each
// asserted by a frozen cross-language vector in contract_test.go and by the
// Elixir, Rust and C implementations independently. Change one and the suite
// reds; change one and every other runtime disagrees with this one.

package brd14

import (
	"errors"
	"time"
)

const (
	// EpochMs is the contract epoch: 2024-01-01T00:00:00Z.
	EpochMs = 1_704_067_200_000
	// Len is the fixed branded length: 3-byte namespace + 11-byte payload.
	Len = 14

	alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
	// base62(2^63-1): lexicographic range guard for the payload.
	maxPayload = "AzL8n0Y58m7"
	// maxSnowflake is the top of the snowflake domain [0, 2^63): an int64, not a
	// full uint64, so every runtime with signed 64-bit integers can hold one.
	maxSnowflake = 1<<63 - 1

	// The arithmetic range guard: the payload split at 62^6 into hi (its
	// first 5 digits, < 62^5) and lo (its last 6, < 62^6), each of which fits
	// a uint64 with room to spare, so neither half can wrap. Since
	// 2^63-1 = qa·62^6 + rb, the value is in range iff hi < qa, or hi == qa and
	// lo <= rb. TestArithmeticGuardConstants pins the identity.
	pow62x6 = 56_800_235_584
	qa      = 162_382_637
	rb      = 503_620_799
)

// ErrInvalid is the one sentinel every refusal in this package satisfies —
// Encode, Parse, Decode, Valid and their byte and append forms all agree on it.
// Compare with errors.Is, never ==: the value actually returned is always one
// of the four typed causes below (ErrLength, ErrNamespace, ErrCharset,
// ErrRange), each of which reports itself as ErrInvalid to errors.Is. A caller
// that only asks "is this a branded id?" keeps asking exactly that; one that
// needs to say WHY it is not asks for the cause.
var ErrInvalid = errors.New("brd14: invalid branded id")

// The typed causes: one per contract error class (docs/contract.md, "Errors
// and precedence" — the C ABI's branded_status codes 1..4). Each is a distinct,
// preallocated value, so a refusal costs no allocation and identifies the rule
// that fired, and errors.Is(err, ErrInvalid) holds for every one of them.
//
// When an input breaks several rules, the reported cause follows the
// contract's namespace-first precedence, the same in every implementation:
//
//	encode: ErrNamespace → ErrRange
//	decode: ErrLength → ErrNamespace → ErrCharset → ErrRange
//
// The most specific, most actionable diagnostic wins — the rule Minter applies
// when its gate runs before the codec.
var (
	// ErrLength refuses a decode input that is not exactly Len bytes.
	ErrLength error = &invalidError{"brd14: invalid branded id: length is not 14 bytes"}
	// ErrNamespace refuses a namespace that is not exactly 3 bytes of A-Z — on
	// encode whatever its length, on decode the first 3 of the 14 bytes.
	ErrNamespace error = &invalidError{"brd14: invalid branded id: namespace is not 3 bytes of A-Z"}
	// ErrCharset refuses a payload byte outside the base62 alphabet 0-9A-Za-z.
	ErrCharset error = &invalidError{"brd14: invalid branded id: payload byte outside the base62 alphabet"}
	// ErrRange refuses a snowflake outside [0, 2^63): on encode a value above
	// 2^63-1, on decode a well-formed payload above "AzL8n0Y58m7".
	ErrRange error = &invalidError{"brd14: invalid branded id: snowflake outside [0, 2^63)"}
)

// invalidError is the type of the typed causes. Each cause is a distinct
// pointer, so == and errors.Is tell the four apart, and its Is method — rather
// than an Unwrap chain — is what lets every one of them satisfy ErrInvalid: the
// causes are siblings under one sentinel, not links a caller has to walk, and
// errors.Is never allocates to answer either question.
type invalidError struct{ msg string }

func (e *invalidError) Error() string { return e.msg }

// Is reports whether target is ErrInvalid. Identity with the cause itself is
// handled by errors.Is before it consults this method.
func (e *invalidError) Is(target error) bool { return target == ErrInvalid }

var values [256]int8

func init() {
	for i := range values {
		values[i] = -1
	}
	for i := 0; i < 62; i++ {
		values[alphabet[i]] = int8(i)
	}
}

// Encode brands a snowflake. ns must be 3 bytes of A-Z (else ErrNamespace) and
// snow must fit int64 (else ErrRange); a namespace fault is reported first.
// The returned string is the only allocation.
func Encode(ns string, snow uint64) (string, error) {
	if err := checkEncode(ns, snow); err != nil {
		return "", err
	}
	var buf [Len]byte
	put(buf[:], ns, snow)
	return string(buf[:]), nil
}

// AppendEncode appends the branded id for (ns, snow) to dst and returns the
// extended slice — Encode for a caller that owns the buffer. A refusal returns
// dst unchanged (same length, same contents) with the typed cause, under
// Encode's precedence. With at least Len bytes of spare capacity in dst it
// allocates nothing; otherwise append's own growth is the only allocation.
//
// The id is written straight into dst's tail rather than built on the stack
// and copied in: measured about 10% faster, and it is the same loop either way.
func AppendEncode(dst []byte, ns string, snow uint64) ([]byte, error) {
	if err := checkEncode(ns, snow); err != nil {
		return dst, err
	}
	n := len(dst)
	dst = append(dst, make([]byte, Len)...) // extends in place: the make never reaches the heap
	put(dst[n:], ns, snow)
	return dst, nil
}

// put writes the 14-byte id for an already-checked (ns, snow) into b[:Len]:
// the namespace, then the 11 base62 digits of snow, least significant last and
// left-padded with '0' — every position is written, the width never trimmed.
func put(b []byte, ns string, snow uint64) {
	_ = b[Len-1] // one bounds check for the fourteen stores below
	_ = ns[2]
	b[0], b[1], b[2] = ns[0], ns[1], ns[2]
	for i := Len - 1; i >= 3; i-- {
		b[i] = alphabet[snow%62] // constant divisor: compiled to multiply, no DIV
		snow /= 62
	}
}

// checkEncode is encode's half of the precedence table: NAMESPACE, then RANGE.
// The length test runs first and short-circuits, so upper3 never indexes a
// namespace shorter than 3 bytes.
func checkEncode(ns string, snow uint64) error {
	if len(ns) != 3 || !upper3(ns) {
		return ErrNamespace
	}
	if snow > maxSnowflake {
		return ErrRange
	}
	return nil
}

// MustEncode is Encode for a caller that has already established ns and snow
// are in the domain; it panics with the typed cause otherwise.
func MustEncode(ns string, snow uint64) string {
	id, err := Encode(ns, snow)
	if err != nil {
		panic(err)
	}
	return id
}

// Parse splits a branded id into namespace and snowflake, gate-checked. It is
// total over every string: a refusal is one of the typed causes, decided in the
// contract's order — ErrLength, ErrNamespace, ErrCharset, ErrRange — with ns ""
// and snow 0. The namespace is a substring of id, so a success allocates
// nothing.
//
// The range guard is the LEXICOGRAPHIC form (payload <= "AzL8n0Y58m7"), exact
// because the alphabet is ASCII-ordered and the width fixed (T-3, T-4). It runs
// after the charset loop, never before: a payload that is both off-alphabet and
// lexicographically above the maximum — "USRzzzzzzzzzz!" — is a CHARSET fault,
// and only the loop can see that.
func Parse(id string) (ns string, snow uint64, err error) {
	if len(id) != Len {
		return "", 0, ErrLength
	}
	if !upper3(id) {
		return "", 0, ErrNamespace
	}
	for i := 3; i < Len; i++ {
		d := values[id[i]]
		if d < 0 {
			return "", 0, ErrCharset
		}
		// Eleven base62 digits reach 62^11 > 2^64, so an out-of-range payload
		// wraps here. Harmless: the guard below refuses it on its bytes, and
		// the wrapped value is never returned.
		snow = snow*62 + uint64(d)
	}
	if id[3:] > maxPayload {
		return "", 0, ErrRange
	}
	return id[:3], snow, nil
}

// Decode is Parse without the namespace.
func Decode(id string) (uint64, error) {
	_, snow, err := Parse(id)
	return snow, err
}

// Valid reports whether id is a well-formed branded id: shape and range. It is
// total and never panics.
func Valid(id string) bool {
	_, _, err := Parse(id)
	return err == nil
}

// ParseBytes is Parse over a byte slice — for ids read straight off a socket,
// a file or a database row, without the string conversion (and its copy) that
// Parse would need. Same totality, same causes, same precedence: ErrLength,
// ErrNamespace, ErrCharset, ErrRange, with zero results on refusal. The
// namespace is returned by value, so nothing allocates, and nothing returned
// aliases b: the caller may reuse the buffer at once.
//
// The range guard is the ARITHMETIC form (see qa and rb), where Parse uses the
// lexicographic one. Both are exact; this one was chosen by measurement. It
// needs no out-of-line byte comparison, and splitting the payload into two
// independent multiply-add chains shortens the dependency chain from eleven
// steps to six; on the bench corpus it measured about 12% faster than the
// lexicographic guard on the same loop (docs/go.md has the numbers). The two
// forms living side by side in one package is also a test asset: FuzzParse and
// the vectors hold Parse and ParseBytes to identical answers, so either guard
// drifting is caught by the other.
func ParseBytes(b []byte) (ns [3]byte, snow uint64, err error) {
	if len(b) != Len {
		return ns, 0, ErrLength
	}
	if !upper(b[0]) || !upper(b[1]) || !upper(b[2]) {
		return ns, 0, ErrNamespace
	}
	var hi, lo uint64
	for _, c := range b[3:8] {
		d := values[c]
		if d < 0 {
			return ns, 0, ErrCharset
		}
		hi = hi*62 + uint64(d)
	}
	for _, c := range b[8:Len] {
		d := values[c]
		if d < 0 {
			return ns, 0, ErrCharset
		}
		lo = lo*62 + uint64(d)
	}
	if hi > qa || hi == qa && lo > rb {
		return ns, 0, ErrRange
	}
	// The namespace leaves as one block copy, not three byte stores. A [3]byte
	// result travels in memory, and a caller reloads it 2+1 bytes wide; built
	// from three separate 1-byte stores, that 2-byte load cannot be forwarded
	// from the store buffer and stalls. The composite literal cost about a
	// third of this function's time; the conversion costs nothing.
	return [3]byte(b[:3]), hi*pow62x6 + lo, nil
}

// DecodeBytes is ParseBytes without the namespace.
func DecodeBytes(b []byte) (uint64, error) {
	_, snow, err := ParseBytes(b)
	return snow, err
}

// ValidBytes is Valid over a byte slice: total, allocation-free.
func ValidBytes(b []byte) bool {
	_, _, err := ParseBytes(b)
	return err == nil
}

// Hash32 is the trie-placement contract hash: the first half of
// MurmurHash3 fmix64, truncated to 32 bits. Vector: Hash32(274557032793636864) == 234878118.
func Hash32(snow uint64) uint32 {
	k := snow
	k ^= k >> 33
	k *= 0xFF51AFD7ED558CCD
	k ^= k >> 33
	return uint32(k)
}

// UnixMs extracts the mint instant.
func UnixMs(snow uint64) int64 { return int64(snow>>22) + EpochMs }

// Time extracts the mint instant as time.Time.
func Time(snow uint64) time.Time { return time.UnixMilli(UnixMs(snow)) }

// MinFor returns the smallest snowflake mintable at or after t — the
// half-open lower bound for time-range scans and synthetic cursors.
func MinFor(t time.Time) uint64 { return uint64(t.UnixMilli()-EpochMs) << 22 }

func upper3(s string) bool {
	return upper(s[0]) && upper(s[1]) && upper(s[2])
}

// upper is the namespace alphabet: A-Z and nothing else. The compiler folds
// the two comparisons into one unsigned subtract-and-compare.
func upper(c byte) bool { return 'A' <= c && c <= 'Z' }
