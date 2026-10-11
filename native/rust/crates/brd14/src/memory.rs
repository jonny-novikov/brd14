//! The **memory** core: the smallest footprint — **zero lookup tables**.
//!
//! The same split at 62^6 as the [`speed`](crate::speed) core, without a byte of read-only
//! data:
//!
//! * **digit → char** is arithmetic: `'0' + d`, plus 7 past `'9'` (skipping `:;<=>?@`) and
//!   6 more past `'Z'` (skipping `` [\]^_` ``). Encode runs one constant divmod per digit,
//!   in two independent chains (5 digits from `hi`, 6 from `lo`).
//! * **char → digit** classifies each byte with three disjoint range masks (`0-9`, `A-Z`,
//!   `a-z`), branch-free and correct for all 256 byte values. An off-alphabet byte selects
//!   no range, so it contributes digit 0 and the accumulators can never wrap.
//! * **the range guard** is arithmetic, checked after the charset: with
//!   `2^63 − 1 = QA · 62^6 + RB`, the value is in range iff
//!   `hi < QA || (hi == QA && lo <= RB)`.
//!
//! Precedence is namespace-first in both directions: encode `NAMESPACE` → `RANGE`;
//! decode `LENGTH` → `NAMESPACE` → `CHARSET` → `RANGE`.

use crate::{Error, LEN, MAX_SNOW, NS_LEN, P62_6, PAYLOAD_LEN, ns_valid};

pub use crate::{hash32, unix_ms};

/// High half of the domain bound: `(2^63 − 1) / 62^6`.
pub const QA: u32 = 162_382_637;
/// Low half of the domain bound: `(2^63 − 1) mod 62^6`.
pub const RB: u64 = 503_620_799;

const _: () = assert!(QA as u64 * P62_6 + RB == MAX_SNOW && RB < P62_6);

/// Size in bytes of the read-only tables this core carries: none.
pub const TABLE_BYTES: usize = 0;

/// Digit (`0..62`) → its alphabet byte, arithmetically and branch-free.
#[inline(always)]
pub const fn char_of(d: u32) -> u8 {
    (d + b'0' as u32 + (d >= 10) as u32 * 7 + (d >= 36) as u32 * 6) as u8
}

/// Byte → `(digit, mask)`: `mask` is `u32::MAX` for a byte of the alphabet and `0`
/// otherwise, in which case `digit` is `0`. Three disjoint range masks, no table, no branch.
#[inline(always)]
pub const fn digit_of(b: u8) -> (u32, u32) {
    let b = b as u32;
    let m_dig = ((b.wrapping_sub(b'0' as u32) < 10) as u32).wrapping_neg();
    let m_up = ((b.wrapping_sub(b'A' as u32) < 26) as u32).wrapping_neg();
    let m_low = ((b.wrapping_sub(b'a' as u32) < 26) as u32).wrapping_neg();
    let d = (m_dig & b.wrapping_sub(b'0' as u32))
        | (m_up & b.wrapping_sub(b'A' as u32 - 10))
        | (m_low & b.wrapping_sub(b'a' as u32 - 36));
    (d, m_dig | m_up | m_low)
}

/// Encode a snowflake (`< 2^63`) under a `3 × [A-Z]` namespace into 14 bytes.
///
/// Precedence: `NAMESPACE` before `RANGE`.
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

    let mut hi = (snowflake / P62_6) as u32; // <= QA < 62^5: payload digits 0..4
    let lo = snowflake % P62_6; //              <  62^6:      payload digits 5..10

    // chain B, first step in 64 bits; the rest of both chains runs in 32 bits.
    out[13] = char_of((lo % 62) as u32);
    let mut l = (lo / 62) as u32; // < 62^5
    let mut i = 12;
    while i > 7 {
        out[i] = char_of(l % 62);
        l /= 62;
        out[i - 5] = char_of(hi % 62); // chain A, interleaved: independent of chain B
        hi /= 62;
        i -= 1;
    }
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

    let mut ok = u32::MAX;
    let mut hi: u32 = 0; // digits 0..4:  < 62^5, never wraps (bad bytes add 0)
    let mut lo: u64 = 0; // digits 5..10: < 62^6
    let mut i = 0;
    while i < 5 {
        let (d, m) = digit_of(p[i]);
        ok &= m;
        hi = hi * 62 + d;
        i += 1;
    }
    while i < PAYLOAD_LEN {
        let (d, m) = digit_of(p[i]);
        ok &= m;
        lo = lo * 62 + d as u64;
        i += 1;
    }
    if ok == 0 {
        return Err(Error::Charset);
    }
    if hi > QA || (hi == QA && lo > RB) {
        return Err(Error::Range);
    }
    Ok((ns, hi as u64 * P62_6 + lo))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ALPHABET;

    #[test]
    fn digit_char_bijection() {
        for d in 0..62u32 {
            assert_eq!(char_of(d), ALPHABET[d as usize]);
            assert_eq!(digit_of(ALPHABET[d as usize]), (d, u32::MAX));
        }
    }

    #[test]
    fn classification_all_256_bytes() {
        for b in 0..=255u8 {
            let want = ALPHABET.iter().position(|&c| c == b);
            match want {
                Some(d) => assert_eq!(digit_of(b), (d as u32, u32::MAX), "byte {b:#04x}"),
                None => assert_eq!(digit_of(b), (0, 0), "byte {b:#04x}"),
            }
        }
    }

    #[test]
    fn contract_vectors() {
        assert_eq!(&encode(b"USR", 274557032793636864).unwrap(), b"USR0KHTOWnGLuC");
        assert_eq!(decode(b"USR0NgWEfAEJfs"), Ok((*b"USR", 320636799581945856)));
        assert_eq!(&encode(b"ABC", 0).unwrap(), b"ABC00000000000");
        assert_eq!(&encode(b"ABC", MAX_SNOW).unwrap()[3..], b"AzL8n0Y58m7");
        assert_eq!(decode(b"USRAzL8n0Y58m7"), Ok((*b"USR", MAX_SNOW)));
        assert_eq!(decode(b"USRAzL8n0Y58m8"), Err(Error::Range));
        assert_eq!(decode(b"USRzzzzzzzzzzz"), Err(Error::Range));
        assert_eq!(decode(b"usr0KHTOWnGLuC"), Err(Error::Namespace));
        assert_eq!(decode(b"USR0KHTOWnGLu"), Err(Error::Length));
        assert_eq!(encode(b"usr", 1 << 63), Err(Error::Namespace));
        assert_eq!(encode(b"USR", 1 << 63), Err(Error::Range));
        assert_eq!(decode(b"USRzzzzzzzzzz!"), Err(Error::Charset));
    }

    #[test]
    fn range_guard_both_sides_of_the_split() {
        // hi == QA: lo decides; hi == QA + 1: refused whatever lo is.
        let at = |hi: u64, lo: u64| encode(b"RNG", hi * P62_6 + lo);
        assert!(at(QA as u64, RB).is_ok());
        assert_eq!(at(QA as u64, RB + 1), Err(Error::Range));
        let top = encode(b"RNG", MAX_SNOW).unwrap();
        assert_eq!(decode(&top), Ok((*b"RNG", MAX_SNOW)));
        let mut above = top;
        above[13] += 1; // "...m7" -> "...m8": hi == QA, lo == RB + 1
        assert_eq!(decode(&above), Err(Error::Range));
        let mut hi_above = top;
        hi_above[7] += 1; // fifth digit up: hi == QA + 1 (lo == RB)
        assert_eq!(decode(&hi_above), Err(Error::Range));
    }
}
