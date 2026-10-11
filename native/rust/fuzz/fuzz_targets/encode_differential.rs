//! encode differential: for any 3 namespace bytes and any u64, both cores agree on the id or
//! the refusal (NAMESPACE before RANGE), and every id decodes back to its input.
#![no_main]

use brd14::{Error, MAX_SNOW, memory, speed};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|input: ([u8; 3], u64)| {
    let (ns, snow) = input;
    let s = speed::encode(&ns, snow);
    let m = memory::encode(&ns, snow);
    assert_eq!(s, m, "speed vs memory on ({ns:?}, {snow})");
    let ns_ok = ns.iter().all(u8::is_ascii_uppercase);
    match s {
        Ok(id) => {
            assert!(ns_ok && snow <= MAX_SNOW);
            assert_eq!(speed::decode(&id), Ok((ns, snow)));
            assert_eq!(memory::decode(&id), Ok((ns, snow)));
        }
        Err(Error::Namespace) => assert!(!ns_ok),
        Err(Error::Range) => assert!(ns_ok && snow > MAX_SNOW),
        Err(e) => panic!("encode cannot refuse with {e:?}"),
    }
});
