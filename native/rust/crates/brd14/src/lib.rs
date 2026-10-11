//! # brd14 — the branded snowflake contract
//!
//! ```text
//! USR0KHTOWnGLuC
//! └┬┘└─────┬────┘
//!  │       └─ payload: 11 chars of base62 over a 63-bit snowflake
//!  └───────── namespace: 3 bytes of A-Z — the brand IS the type
//! ```
//!
//! A `#![no_std]`, allocation-free codec for the brd14 format (`docs/contract.md` is
//! normative). The crate never links `alloc` and contains no `unsafe` code
//! (`#![forbid(unsafe_code)]`); both codecs write into fixed-size arrays they return by
//! value, and every path is total — decode answers every byte string with a value or an
//! [`Error`], never a panic.
//!
//! Two cores implement the same API and are held to identical bytes by the tests and the
//! parity run:
//!
//! | Module | Goal | Read-only tables |
//! |---|---|---|
//! | [`speed`] | fewest cycles per op: pair table, decode table, lexicographic guard | 7,944 bytes |
//! | [`memory`] | smallest footprint: arithmetic digit↔char, range masks, arithmetic guard | none |
//!
//! The crate root re-exports the [`speed`] core, the default, plus the table-free helpers
//! shared by both: [`hash32`], [`unix_ms`], [`fields`], [`min_for`], [`node_from`].
//!
//! ```
//! let id = brd14::encode(b"USR", 274557032793636864).unwrap();
//! assert_eq!(&id, b"USR0KHTOWnGLuC");
//! assert_eq!(brd14::decode(&id), Ok((*b"USR", 274557032793636864)));
//! assert_eq!(brd14::hash32(274557032793636864), 234878118);
//! ```
//!
//! With the `std` feature the crate also provides the lock-free [`Generator`] (and the
//! [`Minter`] policy seam); the codec itself never needs `std`.
#![no_std]
#![forbid(unsafe_code)]

#[cfg(any(test, feature = "std"))]
extern crate std;

pub mod memory;
pub mod speed;

#[cfg(any(test, feature = "std"))]
pub mod generator;

pub use speed::{decode, encode};

#[cfg(any(test, feature = "std"))]
pub use generator::{Clock, Generator, MintError, Minter, SystemClock, allow_all, default_node};

/// Total id length in bytes: namespace + payload.
pub const LEN: usize = 14;
/// Namespace length in bytes (`3 × [A-Z]`).
pub const NS_LEN: usize = 3;
/// Payload length in base62 digits.
pub const PAYLOAD_LEN: usize = 11;
/// The snowflake epoch: 2024-01-01T00:00:00Z in Unix milliseconds.
pub const EPOCH_MS: u64 = 1_704_067_200_000;
/// The largest encodable snowflake, `2^63 − 1`. The domain is `[0, 2^63)`.
pub const MAX_SNOW: u64 = i64::MAX as u64;
/// The payload alphabet, in ASCII order (so byte order == numeric order).
pub const ALPHABET: &[u8; 62] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

/// 62^6 = 3844^3: both cores split the value here into `hi` (5 digits) and `lo` (6 digits).
pub(crate) const P62_6: u64 = 56_800_235_584;

/// A contract refusal. The discriminants are the C ABI's `branded_status` codes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i32)]
pub enum Error {
    /// decode input is not exactly 14 bytes
    Length = 1,
    /// namespace is not exactly 3 bytes of `A-Z`
    Namespace = 2,
    /// a payload byte is outside the alphabet
    Charset = 3,
    /// value outside `[0, 2^63)`
    Range = 4,
}

impl Error {
    /// The C ABI status code (`1..=4`).
    #[inline]
    pub const fn code(self) -> i32 {
        self as i32
    }

    /// The class name used by the parity protocol and the vectors: `LENGTH`, `NAMESPACE`,
    /// `CHARSET` or `RANGE`.
    pub const fn class(self) -> &'static str {
        match self {
            Error::Length => "LENGTH",
            Error::Namespace => "NAMESPACE",
            Error::Charset => "CHARSET",
            Error::Range => "RANGE",
        }
    }
}

impl core::fmt::Display for Error {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        let what = match self {
            Error::Length => "input is not exactly 14 bytes",
            Error::Namespace => "namespace is not exactly 3 bytes of A-Z",
            Error::Charset => "payload byte outside [0-9A-Za-z]",
            Error::Range => "value outside [0, 2^63)",
        };
        write!(f, "brd14: invalid id ({}): {what}", self.class())
    }
}

impl core::error::Error for Error {}

/// `true` iff `ns` is exactly three bytes of `A-Z`. Arithmetic, no table.
#[inline(always)]
pub(crate) fn ns_valid(ns: &[u8; NS_LEN]) -> bool {
    (ns[0].wrapping_sub(b'A') <= 25) & (ns[1].wrapping_sub(b'A') <= 25) & (ns[2].wrapping_sub(b'A') <= 25)
}

/// Trie hash: the first half of MurmurHash3's `fmix64`, truncated to 32 bits.
/// Defined on the full `u64`. Contract vector: `hash32(274557032793636864) == 234878118`.
#[inline]
pub const fn hash32(key: u64) -> u32 {
    let mut k = key;
    k ^= k >> 33;
    k = k.wrapping_mul(0xFF51_AFD7_ED55_8CCD);
    k ^= k >> 33;
    k as u32
}

/// Mint instant of the snowflake as Unix milliseconds: `(snow >> 22) + EPOCH_MS`.
#[inline]
pub const fn unix_ms(snowflake: u64) -> u64 {
    (snowflake >> 22) + EPOCH_MS
}

/// Bits of the sequence field.
pub const SEQ_BITS: u32 = 12;
/// Bits of the node field.
pub const NODE_BITS: u32 = 10;
/// Shift of the timestamp field: `ts(41) << 22 | node(10) << 12 | seq(12)`.
pub const TS_SHIFT: u32 = NODE_BITS + SEQ_BITS;
/// Largest node id, `1023`.
pub const NODE_MAX: u16 = (1 << NODE_BITS) - 1;
/// Largest sequence number, `4095`.
pub const SEQ_MAX: u16 = (1 << SEQ_BITS) - 1;

/// The node field of a snowflake: `(snow >> 12) & 1023`.
#[inline]
pub const fn node_of(snowflake: u64) -> u16 {
    ((snowflake >> SEQ_BITS) & NODE_MAX as u64) as u16
}

/// The sequence field of a snowflake: `snow & 4095`.
#[inline]
pub const fn seq_of(snowflake: u64) -> u16 {
    (snowflake & SEQ_MAX as u64) as u16
}

/// The three fields of a snowflake: `(ts, node, seq)`, `ts` relative to [`EPOCH_MS`].
#[inline]
pub const fn fields(snowflake: u64) -> (u64, u16, u16) {
    (snowflake >> TS_SHIFT, node_of(snowflake), seq_of(snowflake))
}

/// The half-open lower bound for a time-range scan: the smallest snowflake minted at or
/// after `unix_ms`, i.e. `(unix_ms − EPOCH_MS) << 22`.
///
/// Total: an instant before the epoch saturates to `0` (every snowflake qualifies), and one
/// past the 41-bit timestamp horizon saturates to `2^63` (none does).
#[inline]
pub const fn min_for(unix_ms: u64) -> u64 {
    let d = unix_ms.saturating_sub(EPOCH_MS);
    if d >= 1 << 41 { 1 << 63 } else { d << TS_SHIFT }
}

const FNV32_OFFSET: u32 = 0x811C_9DC5;
const FNV32_PRIME: u32 = 0x0100_0193;

/// Derive a 10-bit node id: FNV-32a over `host ++ ASCII-decimal(pid)`, masked to `0..=1023`.
///
/// An empty host hashes the pid alone. The pid is always mixed in, so two processes on one
/// host differ except for a ~1/1024 masked collision. No allocation: the decimal digits are
/// produced into a 10-byte stack buffer.
pub const fn node_from(host: &[u8], pid: u32) -> u16 {
    let mut h = FNV32_OFFSET;
    let mut i = 0;
    while i < host.len() {
        h ^= host[i] as u32;
        h = h.wrapping_mul(FNV32_PRIME);
        i += 1;
    }
    let mut digits = [0u8; 10]; // u32::MAX has 10 decimal digits
    let mut n = 0;
    let mut v = pid;
    loop {
        digits[n] = b'0' + (v % 10) as u8;
        n += 1;
        v /= 10;
        if v == 0 {
            break;
        }
    }
    while n > 0 {
        n -= 1; // most significant digit first
        h ^= digits[n] as u32;
        h = h.wrapping_mul(FNV32_PRIME);
    }
    (h & NODE_MAX as u32) as u16
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn readers_and_node_vectors() {
        assert_eq!(unix_ms(274557032793636864), 1769526697641); // E-1
        assert_eq!(unix_ms(320636799581945856), 1780512970164); // E-2
        let s = 274557032793636864;
        let (ts, node, seq) = fields(s);
        assert_eq!((ts << 22) | (node as u64) << 12 | seq as u64, s);
        assert_eq!(min_for(unix_ms(s)), ts << 22);
        assert!(min_for(unix_ms(s)) <= s && s < min_for(unix_ms(s) + 1));
        assert_eq!(min_for(0), 0);
        assert_eq!(min_for(EPOCH_MS), 0);
        assert_eq!(min_for(EPOCH_MS + (1 << 41) - 1), ((1 << 41) - 1) << 22);
        assert_eq!(min_for(EPOCH_MS + (1 << 41)), 1 << 63);
        assert_eq!(min_for(u64::MAX), 1 << 63);
        // N-1
        assert_eq!(node_from(b"hosta", 100), 585);
        assert_eq!(node_from(b"hosta", 101), 182);
        assert_eq!(node_from(b"hosta", 4242), 290);
        assert_eq!(node_from(b"", 100), 156);
        assert_eq!(node_from(b"", 101), 559);
        assert!(node_from(b"h", u32::MAX) <= NODE_MAX);
    }

    #[test]
    fn contract_vectors() {
        assert_eq!(&encode(b"USR", 274557032793636864).unwrap(), b"USR0KHTOWnGLuC");
        let (ns, v) = decode(b"USR0NgWEfAEJfs").unwrap();
        assert_eq!((&ns, v), (b"USR", 320636799581945856));
        assert_eq!(unix_ms(v), 1780512970164);
        assert_eq!(hash32(274557032793636864), 234878118);
    }

    #[test]
    fn boundaries() {
        let (_, max) = decode(b"USRAzL8n0Y58m7").unwrap();
        assert_eq!(max, MAX_SNOW); // the lex guard's exact ceiling
        assert_eq!(decode(b"USRzzzzzzzzzzz"), Err(Error::Range));
        assert_eq!(encode(b"USR", 1 << 63), Err(Error::Range));
        assert_eq!(decode(b"usr0KHTOWnGLuC"), Err(Error::Namespace));
        assert_eq!(decode(b"USR0KHTOWnGLu*"), Err(Error::Charset));
        assert_eq!(decode(b"USR0KHTOWnGLu"), Err(Error::Length));
        assert_eq!(decode(b"USR0KHTOWnGLuCx"), Err(Error::Length));
        assert_eq!(&encode(b"USR", 0).unwrap(), b"USR00000000000");
    }

    #[test]
    fn precedence_is_namespace_first() {
        // encode: NAMESPACE beats RANGE
        assert_eq!(encode(b"usr", 1 << 63), Err(Error::Namespace));
        assert_eq!(encode(b"US\0", u64::MAX), Err(Error::Namespace));
        // decode: LENGTH > NAMESPACE > CHARSET > RANGE
        assert_eq!(decode(b"usr0KHTOWnGL!!x"), Err(Error::Length));
        assert_eq!(decode(b"usr0KHTOWnGL!!"), Err(Error::Namespace));
        assert_eq!(decode(b"usrzzzzzzzzzzz"), Err(Error::Namespace));
        assert_eq!(decode(b"USRzzzzzzzzzz!"), Err(Error::Charset));
    }

    #[test]
    fn error_codes_and_classes() {
        let all = [Error::Length, Error::Namespace, Error::Charset, Error::Range];
        for (i, e) in all.into_iter().enumerate() {
            assert_eq!(e.code(), i as i32 + 1);
        }
        assert_eq!(Error::Charset.class(), "CHARSET");
        use std::string::ToString;
        assert_eq!(Error::Range.to_string(), "brd14: invalid id (RANGE): value outside [0, 2^63)");
    }

    #[test]
    fn roundtrip() {
        let n = if cfg!(miri) { 2_000 } else { 1_000_000 };
        let mut s: u64 = 0x6A09_E667_F3BC_C909;
        for _ in 0..n {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            let x = s & MAX_SNOW;
            let id = encode(b"CRS", x).unwrap();
            assert_eq!(decode(&id), Ok((*b"CRS", x)));
        }
    }
}
