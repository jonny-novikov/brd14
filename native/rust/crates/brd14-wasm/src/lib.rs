//! # brd14-wasm — the WebAssembly ABI of `docs/contract.md`
//!
//! Raw exports over one static 64 KiB IO region; no imports, no allocator, fixed memory
//! (`initial == max`, set by `build.rs`), so JS views of `memory.buffer` never detach.
//!
//! | Export | Semantics |
//! |---|---|
//! | `io_ptr() → i32` | address of the IO region |
//! | `encode(ns: i32, snow: i64) → i32` | `ns` = 3 bytes packed little-endian; writes 14 bytes at `io[0..14]`; returns the status |
//! | `decode(len: i32) → i64` | reads `len` bytes at `io[0..]`; the snowflake (≥ 0) or `−code` |
//! | `hash32(k: i64) → i32` | `hash32` of `k` reinterpreted as u64, result reinterpreted as i32 |
//! | `encode_many(ns: i32, n: i32) → i32` | `n` i64 at `io[0..8n]` → `14n` bytes at `io[8n..]`; the count encoded before the first error |
//! | `decode_many(n: i32) → i32` | `n × 14` bytes at `io[0..14n]` → `n` i64 at the next 8-aligned offset; returns `n` |
//!
//! Two details the contract leaves to the implementation, both on the side of refusing:
//!
//! * `encode`/`encode_many` treat a non-zero fourth byte of the packed `ns` as a namespace
//!   that is not 3 bytes long: `NAMESPACE`.
//! * the batch exports clamp `n` to `[0, BATCH_MAX]` (2,978: the most whose input and
//!   output fit the region together) and never touch memory outside the IO region. A
//!   caller with more ids chunks them.
//!
//! The core is [`brd14::speed`] by default (see `docs/rust.md` for the measured choice); the
//! `memory` feature selects [`brd14::memory`].
//!
//! On a non-wasm target the crate still compiles (the exports keep their Rust names without
//! `#[no_mangle]`), so the ABI logic is unit-tested natively and under Miri.
#![cfg_attr(not(test), no_std)]

#[cfg(feature = "memory")]
use brd14::memory as imp;
#[cfg(not(feature = "memory"))]
use brd14::speed as imp;

use brd14::{Error, LEN, NS_LEN};

/// The core this module was built with: `"speed"` or `"memory"`.
pub const CORE: &str = if cfg!(feature = "memory") { "memory" } else { "speed" };

/// Size of the IO region in bytes.
pub const IO_LEN: usize = 64 * 1024;

/// The largest `n` the batch exports accept: `round_up_8(14n) + 8n <= IO_LEN`.
pub const BATCH_MAX: usize = 2978;
const _: () = assert!(out_offset(BATCH_MAX) + 8 * BATCH_MAX <= IO_LEN);
const _: () = assert!(out_offset(BATCH_MAX + 1) + 8 * (BATCH_MAX + 1) > IO_LEN);
const _: () = assert!(8 * BATCH_MAX + LEN * BATCH_MAX <= IO_LEN);

#[repr(C, align(16))]
struct Io([u8; IO_LEN]);

/// The IO region. Only ever reached through `&raw mut` (never a reference to the static
/// itself); each export takes one exclusive view for its duration and drops it on return.
static mut IO: Io = Io([0; IO_LEN]);

/// The exclusive view of the IO region for the duration of one export call.
///
/// # Safety
/// No other view may be live: wasm32 here is single-threaded and the exports neither
/// re-enter nor hold the view past their return. (The host tests serialise on a mutex.)
#[inline(always)]
unsafe fn io() -> &'static mut [u8; IO_LEN] {
    let region = &raw mut IO;
    // SAFETY: per the function contract, this is the only live reference to IO.
    unsafe { &mut (*region).0 }
}

/// The 8-aligned offset where `decode_many` writes its output after `n × 14` input bytes.
#[inline(always)]
const fn out_offset(n: usize) -> usize {
    (LEN * n + 7) & !7
}

#[inline(always)]
fn clamp_batch(n: i32) -> usize {
    if n <= 0 { 0 } else { (n as usize).min(BATCH_MAX) }
}

/// Unpack `b0 | b1 << 8 | b2 << 16`; a non-zero fourth byte means "not 3 bytes long".
#[inline(always)]
fn unpack_ns(ns: i32) -> Option<[u8; NS_LEN]> {
    let [b0, b1, b2, b3] = (ns as u32).to_le_bytes();
    if b3 != 0 { None } else { Some([b0, b1, b2]) }
}

/// `decode` result convention: the snowflake (≥ 0), or `−code`.
#[inline(always)]
fn decode_one(id: &[u8]) -> i64 {
    match imp::decode(id) {
        Ok((_, snow)) => snow as i64,
        Err(e) => -(e.code() as i64),
    }
}

/// Address of the IO region (a wasm32 pointer; meaningless on a 64-bit host).
#[cfg_attr(target_arch = "wasm32", unsafe(no_mangle))]
pub extern "C" fn io_ptr() -> i32 {
    (&raw mut IO) as usize as i32
}

/// Encode `snow` under the packed namespace into `io[0..14]`; returns the status code.
/// Precedence: `NAMESPACE`, then `RANGE` (`snow < 0` is outside `[0, 2^63)`).
#[cfg_attr(target_arch = "wasm32", unsafe(no_mangle))]
pub extern "C" fn encode(ns: i32, snow: i64) -> i32 {
    let Some(ns) = unpack_ns(ns) else {
        return Error::Namespace.code();
    };
    match imp::encode(&ns, snow as u64) {
        Ok(id) => {
            // SAFETY: the only view of IO during this call.
            let io = unsafe { io() };
            io[..LEN].copy_from_slice(&id);
            0
        }
        Err(e) => e.code(),
    }
}

/// Decode the `len` bytes at `io[0..]`: the snowflake (≥ 0) or `−code` (−1..−4). On success
/// the namespace is `io[0..3]`.
#[cfg_attr(target_arch = "wasm32", unsafe(no_mangle))]
pub extern "C" fn decode(len: i32) -> i64 {
    if len != LEN as i32 {
        return -(Error::Length.code() as i64); // LENGTH first: no byte needs reading
    }
    // SAFETY: the only view of IO during this call.
    let io = unsafe { io() };
    decode_one(&io[..LEN])
}

/// `hash32` over `k` reinterpreted as u64; the u32 result reinterpreted as i32.
#[cfg_attr(target_arch = "wasm32", unsafe(no_mangle))]
pub extern "C" fn hash32(k: i64) -> i32 {
    imp::hash32(k as u64) as i32
}

/// Encode `n` i64 at `io[0..8n]` into `14n` bytes at `io[8n..]`; returns the count encoded
/// before the first error (`n` when all succeed).
#[cfg_attr(target_arch = "wasm32", unsafe(no_mangle))]
pub extern "C" fn encode_many(ns: i32, n: i32) -> i32 {
    let n = clamp_batch(n);
    let Some(ns) = unpack_ns(ns) else {
        return 0;
    };
    // SAFETY: the only view of IO during this call.
    let io = unsafe { io() };
    let (input, rest) = io.split_at_mut(8 * n);
    for (i, (src, dst)) in input.chunks_exact(8).zip(rest.chunks_exact_mut(LEN)).enumerate() {
        let mut le = [0u8; 8];
        le.copy_from_slice(src);
        match imp::encode(&ns, u64::from_le_bytes(le)) {
            Ok(id) => dst.copy_from_slice(&id),
            Err(_) => return i as i32,
        }
    }
    n as i32
}

/// Decode `n × 14` bytes at `io[0..14n]` into `n` i64 (snowflake or `−code`) at the next
/// 8-aligned offset; returns `n`.
#[cfg_attr(target_arch = "wasm32", unsafe(no_mangle))]
pub extern "C" fn decode_many(n: i32) -> i32 {
    let n = clamp_batch(n);
    // SAFETY: the only view of IO during this call.
    let io = unsafe { io() };
    let (input, rest) = io.split_at_mut(out_offset(n));
    for (src, dst) in input[..LEN * n].chunks_exact(LEN).zip(rest.chunks_exact_mut(8)) {
        dst.copy_from_slice(&decode_one(src).to_le_bytes());
    }
    n as i32
}

#[cfg(all(not(test), target_arch = "wasm32"))]
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    core::arch::wasm32::unreachable()
}

#[cfg(all(not(test), not(target_arch = "wasm32")))]
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    loop {
        core::hint::spin_loop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, MutexGuard};

    /// The exports share one static region: tests take turns.
    static LOCK: Mutex<()> = Mutex::new(());

    fn lock() -> MutexGuard<'static, ()> {
        LOCK.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn pack(ns: &[u8]) -> i32 {
        ns.iter().take(3).enumerate().fold(0, |a, (i, &b)| a | (b as i32) << (8 * i))
    }

    fn io_bytes() -> &'static mut [u8; IO_LEN] {
        unsafe { io() }
    }

    #[test]
    fn single_ops_contract_vectors() {
        let _g = lock();
        assert_eq!(encode(pack(b"USR"), 274557032793636864), 0); // V-1
        assert_eq!(&io_bytes()[..14], b"USR0KHTOWnGLuC");
        assert_eq!(decode(14), 274557032793636864);
        io_bytes()[..14].copy_from_slice(b"USR0NgWEfAEJfs"); // V-2
        assert_eq!(decode(14), 320636799581945856);
        assert_eq!(&io_bytes()[..3], b"USR");
        assert_eq!(hash32(274557032793636864) as u32, 234878118); // V-6
        assert_eq!(hash32(-1) as u32, brd14::hash32(u64::MAX));
        assert_eq!(encode(pack(b"ABC"), i64::MAX), 0); // V-4
        assert_eq!(&io_bytes()[3..14], b"AzL8n0Y58m7");
    }

    #[test]
    fn single_op_refusals() {
        let _g = lock();
        io_bytes()[..14].copy_from_slice(b"XXXXXXXXXXXXXX");
        assert_eq!(encode(pack(b"usr"), 1), 2);
        assert_eq!(encode(pack(b"US"), 1), 2); // short: a 0 byte
        assert_eq!(encode(pack(b"USR") | 0x41 << 24, 1), 2); // a fourth byte
        assert_eq!(encode(pack(b"usr"), -1), 2); // NAMESPACE before RANGE
        assert_eq!(encode(pack(b"USR"), -1), 4);
        assert_eq!(encode(pack(b"USR"), i64::MIN), 4);
        assert_eq!(&io_bytes()[..14], b"XXXXXXXXXXXXXX"); // refusals write nothing
        for len in [-1, 0, 13, 15, 65536, i32::MAX, i32::MIN] {
            assert_eq!(decode(len), -1);
        }
        for (id, code) in [(b"USRzzzzzzzzzzz", -4), (b"usr0KHTOWnGLuC", -2), (b"USRzzzzzzzzzz!", -3)] {
            io_bytes()[..14].copy_from_slice(id);
            assert_eq!(decode(14), code);
        }
    }

    #[test]
    fn batches_round_trip() {
        let _g = lock();
        let n = if cfg!(miri) { 40 } else { BATCH_MAX };
        let snows: Vec<i64> =
            (0..n as i64).map(|i| i.wrapping_mul(0x5DEE_CE66_D1CE_4E5B) & i64::MAX).collect();
        for (i, s) in snows.iter().enumerate() {
            io_bytes()[8 * i..8 * i + 8].copy_from_slice(&s.to_le_bytes());
        }
        assert_eq!(encode_many(pack(b"BAT"), n as i32), n as i32);
        let ids: Vec<[u8; 14]> =
            (0..n).map(|i| io_bytes()[8 * n + 14 * i..8 * n + 14 * i + 14].try_into().unwrap()).collect();
        for (id, &s) in ids.iter().zip(&snows) {
            assert_eq!(brd14::decode(id), Ok((*b"BAT", s as u64)));
        }
        // decode them back in one batch, with one bad id in the middle
        for (i, id) in ids.iter().enumerate() {
            io_bytes()[14 * i..14 * i + 14].copy_from_slice(id);
        }
        io_bytes()[14 * 3] = b'b'; // namespace of id 3
        assert_eq!(decode_many(n as i32), n as i32);
        let off = out_offset(n);
        assert_eq!(off % 8, 0);
        for (i, &s) in snows.iter().enumerate() {
            let got = i64::from_le_bytes(io_bytes()[off + 8 * i..off + 8 * i + 8].try_into().unwrap());
            assert_eq!(got, if i == 3 { -2 } else { s }, "id {i}");
        }
    }

    #[test]
    fn encode_many_stops_at_the_first_error() {
        let _g = lock();
        for (i, s) in [1i64, 2, -5, 4].iter().enumerate() {
            io_bytes()[8 * i..8 * i + 8].copy_from_slice(&s.to_le_bytes());
        }
        assert_eq!(encode_many(pack(b"ERR"), 4), 2);
        assert_eq!(&io_bytes()[32..46], b"ERR00000000001");
        assert_eq!(encode_many(pack(b"err"), 4), 0);
        assert_eq!(encode_many(pack(b"ERR") | 1 << 24, 4), 0);
    }

    #[test]
    fn batch_sizes_are_clamped_to_the_region() {
        let _g = lock();
        assert_eq!(decode_many(-7), 0);
        assert_eq!(decode_many(0), 0);
        assert_eq!(encode_many(pack(b"CLP"), i32::MIN), 0);
        if !cfg!(miri) {
            io_bytes().fill(b'0');
            assert_eq!(decode_many(i32::MAX), BATCH_MAX as i32);
            io_bytes().fill(0);
            assert_eq!(encode_many(pack(b"CLP"), i32::MAX), BATCH_MAX as i32);
        }
    }
}
