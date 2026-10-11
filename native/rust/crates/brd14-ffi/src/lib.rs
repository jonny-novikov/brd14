//! # brd14-ffi — the C ABI of `native/include/branded_id.h`, in Rust
//!
//! A drop-in for the C cores: the same four symbols with the same signatures and the same
//! status codes, so a consumer (the BEAM NIF, the C bench) links `libbrd14_ffi.so` or
//! `libbrd14_ffi.a` instead of a C object and nothing else changes. The parity run holds
//! both to identical bytes.
//!
//! The core behind the ABI is [`brd14::speed`] by default; the `memory` feature selects
//! the table-free [`brd14::memory`] core. The symbols and their behaviour are identical.
//!
//! The crate is `no_std` with its own panic handler: the shared object links no Rust
//! standard library and no allocator (`nm -u` shows no `malloc`/`free`).
#![cfg_attr(not(test), no_std)]

#[cfg(feature = "memory")]
use brd14::memory as imp;
#[cfg(not(feature = "memory"))]
use brd14::speed as imp;

/// The core this build exports: `"speed"` or `"memory"`.
pub const CORE: &str = if cfg!(feature = "memory") { "memory" } else { "speed" };
use brd14::{Error, LEN, NS_LEN};

/// `BRANDED_OK`.
pub const BRANDED_OK: i32 = 0;

/// `branded_status branded_encode(const char ns[3], uint64_t snowflake, char out[14])`
///
/// Writes exactly 14 bytes to `out` on success (no NUL). Precedence: `NAMESPACE`, then
/// `RANGE`. A null `ns` or `out` is refused with `BRANDED_ERR_NAMESPACE` and nothing is written.
///
/// # Safety
/// `ns` must be null or point to 3 readable bytes; `out` must be null or point to 14
/// writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn branded_encode(ns: *const u8, snowflake: u64, out: *mut u8) -> i32 {
    if ns.is_null() || out.is_null() {
        return Error::Namespace.code();
    }
    // SAFETY: the caller guarantees 3 readable bytes at `ns`; [u8; 3] has alignment 1.
    let ns3 = unsafe { ns.cast::<[u8; NS_LEN]>().read() };
    match imp::encode(&ns3, snowflake) {
        Ok(id) => {
            // SAFETY: the caller guarantees 14 writable bytes at `out`; alignment 1.
            unsafe { out.cast::<[u8; LEN]>().write(id) };
            BRANDED_OK
        }
        Err(e) => e.code(),
    }
}

/// `branded_status branded_decode(const char *id, size_t len, char ns_out[3], uint64_t *snowflake_out)`
///
/// On success fills `ns_out` (3 bytes, no NUL) and `*snowflake_out` (`< 2^63`); on refusal
/// writes nothing. Precedence: `LENGTH`, `NAMESPACE`, `CHARSET`, `RANGE`. A null pointer is
/// refused with `BRANDED_ERR_LENGTH`.
///
/// # Safety
/// `id` must be null or point to `len` readable bytes; `ns_out` must be null or point to 3
/// writable bytes; `snowflake_out` must be null or point to 8 writable bytes (any alignment).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn branded_decode(
    id: *const u8,
    len: usize,
    ns_out: *mut u8,
    snowflake_out: *mut u64,
) -> i32 {
    if id.is_null() || ns_out.is_null() || snowflake_out.is_null() {
        return Error::Length.code();
    }
    // SAFETY: the caller guarantees `len` readable bytes at the non-null `id`.
    let bytes = unsafe { core::slice::from_raw_parts(id, len) };
    match imp::decode(bytes) {
        Ok((ns, snow)) => {
            // SAFETY: the caller guarantees 3 writable bytes at `ns_out` and 8 at
            // `snowflake_out`; the unaligned write tolerates any alignment.
            unsafe {
                ns_out.cast::<[u8; NS_LEN]>().write(ns);
                snowflake_out.write_unaligned(snow);
            }
            BRANDED_OK
        }
        Err(e) => e.code(),
    }
}

/// `uint32_t branded_hash32(uint64_t key)` — the first half of MurmurHash3 `fmix64`, truncated.
#[unsafe(no_mangle)]
pub extern "C" fn branded_hash32(key: u64) -> u32 {
    imp::hash32(key)
}

/// `uint64_t branded_unix_ms(uint64_t snowflake)` — the mint instant in Unix milliseconds.
#[unsafe(no_mangle)]
pub extern "C" fn branded_unix_ms(snowflake: u64) -> u64 {
    imp::unix_ms(snowflake)
}

#[cfg(not(test))]
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    // Unreachable: no exported path can panic (every index is proven in bounds and the
    // arithmetic is explicit about wrapping). Spin rather than invoke UB.
    loop {
        core::hint::spin_loop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use core::ptr;

    fn enc(ns: &[u8; 3], snow: u64) -> Result<[u8; 14], i32> {
        let mut out = [0u8; 14];
        match unsafe { branded_encode(ns.as_ptr(), snow, out.as_mut_ptr()) } {
            0 => Ok(out),
            e => Err(e),
        }
    }

    fn dec(id: &[u8]) -> Result<([u8; 3], u64), i32> {
        let mut ns = [0u8; 3];
        let mut snow = 0u64;
        match unsafe { branded_decode(id.as_ptr(), id.len(), ns.as_mut_ptr(), &mut snow) } {
            0 => Ok((ns, snow)),
            e => Err(e),
        }
    }

    #[test]
    fn contract_vectors() {
        assert_eq!(&enc(b"USR", 274557032793636864).unwrap(), b"USR0KHTOWnGLuC"); // V-1
        assert_eq!(dec(b"USR0NgWEfAEJfs"), Ok((*b"USR", 320636799581945856))); // V-2
        assert_eq!(&enc(b"ABC", 0).unwrap(), b"ABC00000000000"); // V-3
        assert_eq!(&enc(b"ABC", i64::MAX as u64).unwrap()[3..], b"AzL8n0Y58m7"); // V-4
        assert_eq!(dec(b"USRzzzzzzzzzzz"), Err(4)); // V-5
        assert_eq!(dec(b"usr0KHTOWnGLuC"), Err(2));
        assert_eq!(dec(b"USR0KHTOWnGLu"), Err(1));
        assert_eq!(dec(b"USR0KHTOWnGLuCC"), Err(1));
        assert_eq!(branded_hash32(274557032793636864), 234878118); // V-6
        assert_eq!(branded_unix_ms(274557032793636864), 1769526697641); // E-1
        assert_eq!(branded_unix_ms(320636799581945856), 1780512970164); // E-2
    }

    #[test]
    fn precedence_is_namespace_first() {
        assert_eq!(enc(b"usr", 1 << 63), Err(2));
        assert_eq!(enc(b"USR", 1 << 63), Err(4));
        assert_eq!(dec(b"usr0KHTOWnGL!!"), Err(2));
        assert_eq!(dec(b"USRzzzzzzzzzz!"), Err(3));
        assert_eq!(dec(b"usr0KHTOWnGL!!!"), Err(1));
    }

    #[test]
    fn refusals_write_nothing() {
        let mut out = [0xAAu8; 14];
        assert_eq!(unsafe { branded_encode(b"usr".as_ptr(), 0, out.as_mut_ptr()) }, 2);
        assert_eq!(out, [0xAA; 14]);
        let (mut ns, mut snow) = ([0xAAu8; 3], 7u64);
        let id = b"USRzzzzzzzzzzz";
        assert_eq!(unsafe { branded_decode(id.as_ptr(), 14, ns.as_mut_ptr(), &mut snow) }, 4);
        assert_eq!((ns, snow), ([0xAA; 3], 7));
    }

    #[test]
    fn null_pointers_are_refused() {
        let mut out = [0u8; 14];
        let (mut ns, mut snow) = ([0u8; 3], 0u64);
        unsafe {
            assert_eq!(branded_encode(ptr::null(), 0, out.as_mut_ptr()), 2);
            assert_eq!(branded_encode(b"USR".as_ptr(), 0, ptr::null_mut()), 2);
            assert_eq!(branded_decode(ptr::null(), 14, ns.as_mut_ptr(), &mut snow), 1);
            assert_eq!(branded_decode(b"USR0NgWEfAEJfs".as_ptr(), 14, ptr::null_mut(), &mut snow), 1);
            assert_eq!(branded_decode(b"USR0NgWEfAEJfs".as_ptr(), 14, ns.as_mut_ptr(), ptr::null_mut()), 1);
        }
    }

    #[test]
    fn unaligned_snowflake_out() {
        let mut buf = [0u8; 16];
        let mut ns = [0u8; 3];
        let p = unsafe { buf.as_mut_ptr().add(1) }.cast::<u64>();
        let id = b"USR0NgWEfAEJfs";
        assert_eq!(unsafe { branded_decode(id.as_ptr(), 14, ns.as_mut_ptr(), p) }, 0);
        assert_eq!(u64::from_ne_bytes(buf[1..9].try_into().unwrap()), 320636799581945856);
    }
}
