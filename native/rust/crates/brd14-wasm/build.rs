//! Fixed linear memory for the wasm32 build, scoped to this crate's cdylib.
//!
//! These flags live here rather than in `.cargo/config.toml` so they apply wherever cargo
//! is invoked from (a config file is only found relative to the working directory).
//!
//! Layout (wasm-ld, stack first): 64 KiB stack | static data (the speed core's ~8 KB of
//! tables) | the 64 KiB IO region. Three 64 KiB pages hold it with room to spare, and
//! `initial == max` means `memory.grow` always fails, so a JS view of `memory.buffer` is
//! never detached.

const PAGE: u32 = 64 * 1024;
const PAGES: u32 = 3;
const STACK: u32 = 64 * 1024;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    if std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("wasm32") {
        let bytes = PAGES * PAGE;
        for arg in [
            format!("--initial-memory={bytes}"),
            format!("--max-memory={bytes}"),
            format!("-zstack-size={STACK}"),
            // no name/producers custom sections: the module is the ABI and nothing else
            "--strip-all".to_owned(),
        ] {
            println!("cargo:rustc-link-arg-cdylib={arg}");
        }
    }
}
