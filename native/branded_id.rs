// branded_id.rs — the branded Snowflake contract in Rust.
//
// Same algorithms as branded_id.c (split-chain pair-table encoder, split
// decoder with the lexicographic range guard), same contract vectors, and the
// same C ABI: built as a cdylib this library is a drop-in replacement for the
// C object — the C bench links against either and must print identical
// vectors and pass the same property test.
//
//   tests:  rustc --test -C opt-level=3 -o branded_test branded_id.rs && ./branded_test
//   cdylib: rustc --crate-type cdylib -C opt-level=3 -o libbranded_rs.so branded_id.rs
//
// The core is no_std and allocation-free: tables are const-evaluated, both
// codecs write into caller arrays, and no code path can panic (accumulators
// use wrapping arithmetic on the already-rejected invalid path).
#![cfg_attr(not(test), no_std)]

pub const LEN: usize = 14;
pub const NS_LEN: usize = 3;
pub const PAYLOAD_LEN: usize = 11;
pub const EPOCH_MS: u64 = 1_704_067_200_000; // 2024-01-01T00:00:00Z

const P62_6: u64 = 56_800_235_584; // 62^6 = 3844^3
const ALPHABET: &[u8; 62] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const MAX_PAYLOAD: &[u8; PAYLOAD_LEN] = b"AzL8n0Y58m7"; // base62(2^63 - 1)

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
/// PAIRS[2k], PAIRS[2k+1] = the two base62 digits of k, for k in [0, 3844).
const PAIRS: [u8; 62 * 62 * 2] = build_pairs();

const fn build_decode() -> [u8; 256] {
    let mut t = [0u8; 256]; // 0 marks an invalid byte; valid bytes map to digit + 1
    let mut i = 0;
    while i < 62 {
        t[ALPHABET[i] as usize] = (i as u8) + 1;
        i += 1;
    }
    t
}
const DECODE: [u8; 256] = build_decode();

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum Error {
    Length = 1,
    Namespace = 2,
    Charset = 3,
    Range = 4,
}

#[inline]
fn ns_valid(ns: &[u8]) -> bool {
    ns.len() == NS_LEN && ns.iter().all(|&c| c.wrapping_sub(b'A') <= 25)
}

#[inline]
fn put_pair(out: &mut [u8; LEN], at: usize, k: usize) {
    out[at] = PAIRS[2 * k];
    out[at + 1] = PAIRS[2 * k + 1];
}

/// Encode a snowflake (< 2^63) under a 3 x [A-Z] namespace into 14 bytes.
pub fn encode(ns: &[u8; NS_LEN], snowflake: u64) -> Result<[u8; LEN], Error> {
    if snowflake > i64::MAX as u64 {
        return Err(Error::Range);
    }
    if !ns_valid(ns) {
        return Err(Error::Namespace);
    }
    let mut out = [0u8; LEN];
    out[..NS_LEN].copy_from_slice(ns);

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

/// Decode exactly 14 bytes into (namespace, snowflake < 2^63).
/// Validation order: length, namespace, charset, range.
pub fn decode(id: &[u8]) -> Result<([u8; NS_LEN], u64), Error> {
    if id.len() != LEN {
        return Err(Error::Length);
    }
    if !ns_valid(&id[..NS_LEN]) {
        return Err(Error::Namespace);
    }
    let p = &id[NS_LEN..LEN];

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
    // Lexicographic order equals numeric order for this format, so the range
    // check is a fixed-width compare against base62(2^63 - 1). Past it, the
    // accumulators above are provably wrap-free.
    if p > &MAX_PAYLOAD[..] {
        return Err(Error::Range);
    }

    let mut ns = [0u8; NS_LEN];
    ns.copy_from_slice(&id[..NS_LEN]);
    Ok((ns, (hi as u64) * P62_6 + lo))
}

/// Trie hash: the first half of MurmurHash3's fmix64, truncated to 32 bits.
/// Contract vector: hash32(274557032793636864) == 234878118.
pub fn hash32(key: u64) -> u32 {
    let mut k = key;
    k ^= k >> 33;
    k = k.wrapping_mul(0xFF51_AFD7_ED55_8CCD);
    k ^= k >> 33;
    k as u32
}

/// Mint instant of the snowflake as Unix milliseconds.
pub fn unix_ms(snowflake: u64) -> u64 {
    (snowflake >> 22) + EPOCH_MS
}

// ---- C ABI (drop-in for branded_id.h) --------------------------------------

/// # Safety
/// `ns` must point to 3 readable bytes; `out` to 14 writable bytes.
#[no_mangle]
pub unsafe extern "C" fn branded_encode(ns: *const u8, snowflake: u64, out: *mut u8) -> i32 {
    if ns.is_null() || out.is_null() {
        return Error::Namespace as i32;
    }
    let ns3 = &*(ns as *const [u8; NS_LEN]);
    match encode(ns3, snowflake) {
        Ok(buf) => {
            core::ptr::copy_nonoverlapping(buf.as_ptr(), out, LEN);
            0
        }
        Err(e) => e as i32,
    }
}

/// # Safety
/// `id` must point to `len` readable bytes; `ns_out` to 3 and `snowflake_out`
/// to 8 writable bytes.
#[no_mangle]
pub unsafe extern "C" fn branded_decode(
    id: *const u8,
    len: usize,
    ns_out: *mut u8,
    snowflake_out: *mut u64,
) -> i32 {
    if id.is_null() || ns_out.is_null() || snowflake_out.is_null() {
        return Error::Length as i32;
    }
    let s = core::slice::from_raw_parts(id, len);
    match decode(s) {
        Ok((ns, v)) => {
            core::ptr::copy_nonoverlapping(ns.as_ptr(), ns_out, NS_LEN);
            *snowflake_out = v;
            0
        }
        Err(e) => e as i32,
    }
}

#[no_mangle]
pub extern "C" fn branded_hash32(key: u64) -> u32 {
    hash32(key)
}

#[no_mangle]
pub extern "C" fn branded_unix_ms(snowflake: u64) -> u64 {
    unix_ms(snowflake)
}

#[cfg(not(test))]
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    loop {} // unreachable: the library has no panicking paths
}

// ---- tests ------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

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
        assert_eq!(max, i64::MAX as u64); // the lex guard's exact ceiling
        assert_eq!(decode(b"USRzzzzzzzzzzz"), Err(Error::Range));
        assert_eq!(encode(b"USR", 1 << 63), Err(Error::Range));
        assert_eq!(decode(b"usr0KHTOWnGLuC"), Err(Error::Namespace));
        assert_eq!(decode(b"USR0KHTOWnGLu*"), Err(Error::Charset));
        assert_eq!(decode(b"USR0KHTOWnGLu"), Err(Error::Length));
        assert_eq!(decode(b"USR0KHTOWnGLuCx"), Err(Error::Length));
        assert_eq!(&encode(b"USR", 0).unwrap(), b"USR00000000000");
    }

    #[test]
    fn roundtrip_one_million() {
        let mut s: u64 = 0x6A09_E667_F3BC_C909;
        for _ in 0..1_000_000 {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            let x = s & 0x7FFF_FFFF_FFFF_FFFF;
            let id = encode(b"CRS", x).unwrap();
            let (ns, back) = decode(&id).unwrap();
            assert_eq!((&ns, back), (b"CRS", x));
        }
    }
}
