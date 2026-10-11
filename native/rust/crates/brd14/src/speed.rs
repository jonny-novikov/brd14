//! The **speed** core: fewest cycles per operation.
//!
//! * **encode** splits the value at 62^6 into `hi` (5 digits) and `lo` (6 digits): two
//!   independent divmod chains the CPU overlaps, both in 32-bit registers after their first
//!   step, and each step emits **two** digits through a 62×62 pair table (`PAIRS`, 7,688
//!   bytes), so the chains run 2 + 2 constant divmods instead of 5 + 6. Every divisor is a
//!   compile-time constant, strength-reduced to multiply + shift.
//! * **decode** maps each byte through one 256-byte table (`DECODE`: digit + 1, 0 = invalid),
//!   so the charset check and the digit extraction share a load and the check is branchless.
//!   The range guard is **lexicographic**: the payload is fixed-width over an ASCII-ordered
//!   alphabet, so `value < 2^63` is `payload <= "AzL8n0Y58m7"` bytewise — compared as two
//!   big-endian words (bytes 0..8, bytes 8..11) in registers, with no `memcmp` call.
//!
//! Both tables are built by `const fn` at compile time and live in read-only data
//! (about 8 KB). The [`memory`](crate::memory) core carries none of them.
//!
//! Precedence is namespace-first in both directions: encode `NAMESPACE` → `RANGE`;
//! decode `LENGTH` → `NAMESPACE` → `CHARSET` → `RANGE`.

use crate::{ALPHABET, Error, LEN, MAX_SNOW, NS_LEN, P62_6, PAYLOAD_LEN, ns_valid};

pub use crate::{hash32, unix_ms};

/// base62(2^63 − 1): the largest valid payload.
const MAX_PAYLOAD: &[u8; PAYLOAD_LEN] = b"AzL8n0Y58m7";

/// The payload as two big-endian words, `(bytes 0..8, bytes 8..11)`: comparing the pairs
/// compares the 11 bytes lexicographically, in registers rather than through `memcmp`.
#[inline(always)]
const fn be_words(p: &[u8; PAYLOAD_LEN]) -> (u64, u32) {
    let [a0, a1, a2, a3, a4, a5, a6, a7, b0, b1, b2] = *p;
    (u64::from_be_bytes([a0, a1, a2, a3, a4, a5, a6, a7]), u32::from_be_bytes([0, b0, b1, b2]))
}
const MAX_WORDS: (u64, u32) = be_words(MAX_PAYLOAD);

const fn build_pairs() -> [u8; 62 * 62 * 2] {
    let mut t = [0u8; 62 * 62 * 2];
    let mut k = 0;
    while k < 62 * 62 {
        t[2 * k] = ALPHABET[k / 62];
        t[2 * k + 1] = ALPHABET[k % 62];
        k += 1;
    }
    t
}

/// `PAIRS[2k]`, `PAIRS[2k + 1]` = the two base62 digits of `k`, for `k` in `[0, 3844)`.
static PAIRS: [u8; 62 * 62 * 2] = build_pairs();

const fn build_decode() -> [u8; 256] {
    let mut t = [0u8; 256]; // 0 marks an invalid byte; valid bytes map to digit + 1
    let mut i = 0;
    while i < 62 {
        t[ALPHABET[i] as usize] = (i as u8) + 1;
        i += 1;
    }
    t
}

/// byte → base62 digit + 1; 0 marks a byte outside the alphabet.
static DECODE: [u8; 256] = build_decode();

/// Size in bytes of the read-only tables this core carries (pair table + decode table).
pub const TABLE_BYTES: usize = 62 * 62 * 2 + 256;

#[inline(always)]
fn put_pair(out: &mut [u8; LEN], at: usize, k: usize) {
    out[at] = PAIRS[2 * k];
    out[at + 1] = PAIRS[2 * k + 1];
}

/// Encode a snowflake (`< 2^63`) under a `3 × [A-Z]` namespace into 14 bytes.
///
///
/// Precedence: `NAMESPACE` before `RANGE` (namespace-first, the most specific diagnostic).
#[inline]
pub fn encode(ns: &[u8; NS_LEN], snowflake: u64) -> Result<[u8; LEN], Error> {
    if !ns_valid(ns) {
        return Err(Error::Namespace);
    }
    if snowflake > MAX_SNOW {
        return Err(Error::Range);
    }
    let mut out = [0u8; LEN];
    out[0] = ns[0];
    out[1] = ns[1];
    out[2] = ns[2];

    let mut hi = (snowflake / P62_6) as u32; // < 62^5: payload digits 0..4
    let lo = snowflake % P62_6; //              < 62^6: payload digits 5..10

    // chain A: 2 divmods (payload digits live at out[3..14])
    put_pair(&mut out, 6, (hi % 3844) as usize);
    hi /= 3844;
    put_pair(&mut out, 4, (hi % 3844) as usize);
    hi /= 3844;
    out[3] = ALPHABET[hi as usize]; // hi < 62

    // chain B: 2 divmods, independent of chain A
    put_pair(&mut out, 12, (lo % 3844) as usize);
    let mut l = (lo / 3844) as u32; // < 62^4
    put_pair(&mut out, 10, (l % 3844) as usize);
    l /= 3844;
    put_pair(&mut out, 8, l as usize); // l < 3844: itself a pair index

    Ok(out)
}

/// Decode exactly 14 bytes into `(namespace, snowflake < 2^63)`.
///
/// Total over every byte string. Precedence: `LENGTH`, `NAMESPACE`, `CHARSET`, `RANGE`.
#[inline]
pub fn decode(id: &[u8]) -> Result<([u8; NS_LEN], u64), Error> {
    let Ok(id) = <&[u8; LEN]>::try_from(id) else {
        return Err(Error::Length);
    };
    let [n0, n1, n2, p @ ..] = id;
    let ns = [*n0, *n1, *n2];
    if !ns_valid(&ns) {
        return Err(Error::Namespace);
    }

    let mut bad = 0u8;
    let mut hi: u32 = 0; // digits 0..4:  < 62^5
    let mut lo: u64 = 0; // digits 5..10: < 62^6
    let mut i = 0;
    while i < 5 {
        let d = DECODE[p[i] as usize];
        bad |= (d == 0) as u8;
        hi = hi.wrapping_mul(62).wrapping_add((d as u32).wrapping_sub(1));
        i += 1;
    }
    while i < PAYLOAD_LEN {
        let d = DECODE[p[i] as usize];
        bad |= (d == 0) as u8;
        lo = lo.wrapping_mul(62).wrapping_add((d as u64).wrapping_sub(1));
        i += 1;
    }
    if bad != 0 {
        return Err(Error::Charset);
    }
    // Lexicographic order equals numeric order for this format, so the range check is a
    // fixed-width bytewise compare against base62(2^63 − 1), done as two big-endian words.
    // Past it, the accumulators above are provably wrap-free.
    if be_words(p) > MAX_WORDS {
        return Err(Error::Range);
    }
    Ok((ns, (hi as u64) * P62_6 + lo))
}
