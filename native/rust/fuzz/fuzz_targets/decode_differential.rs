//! decode differential: the speed core, the memory core and an independent u128 reference
//! must agree on every byte string, and every accepted id must round-trip byte for byte
//! through both encoders (the format is canonical: one id per (ns, snowflake)).
#![no_main]

use brd14::{ALPHABET, Error, MAX_SNOW, memory, speed};
use libfuzzer_sys::fuzz_target;

fn reference(id: &[u8]) -> Result<([u8; 3], u64), Error> {
    if id.len() != 14 {
        return Err(Error::Length);
    }
    if !id[..3].iter().all(u8::is_ascii_uppercase) {
        return Err(Error::Namespace);
    }
    let mut v: u128 = 0;
    for &b in &id[3..] {
        let Some(d) = ALPHABET.iter().position(|&c| c == b) else { return Err(Error::Charset) };
        v = v * 62 + d as u128;
    }
    if v > MAX_SNOW as u128 {
        return Err(Error::Range);
    }
    Ok(([id[0], id[1], id[2]], v as u64))
}

fuzz_target!(|data: &[u8]| {
    let s = speed::decode(data);
    let m = memory::decode(data);
    assert_eq!(s, m, "speed vs memory on {data:?}");
    assert_eq!(s, reference(data), "cores vs reference on {data:?}");
    if let Ok((ns, snow)) = s {
        let a = speed::encode(&ns, snow).expect("an accepted id re-encodes");
        let b = memory::encode(&ns, snow).expect("an accepted id re-encodes");
        assert_eq!(&a[..], data, "speed round trip");
        assert_eq!(a, b, "speed vs memory encode");
    }
});
