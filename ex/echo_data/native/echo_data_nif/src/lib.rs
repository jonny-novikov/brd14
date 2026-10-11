//! `EchoData.Native`: the brd14 codec and the persistent branded champ, for the BEAM.
//!
//! Codec — `decode/1`, `decode_hash/1`, `encode/2`, `hash32/1` — keeps the exact API of the C
//! shim it replaces, so `EchoData.BrandedId` is unchanged: `:error` on refusal, the classified
//! reasons stay in Elixir (`BrandedId.validate/1`).
//!
//! Champ — a `brd14_data::Champ` behind a resource. Every write returns a NEW resource and
//! leaves the old one valid: value semantics, like an Elixir map, with the trie shared between
//! versions. Values are stored as external term format (`term_to_binary`), so any term goes in
//! and an equal term comes out, held off the process heap and shared across processes by
//! reference. Calls that walk the whole champ run on dirty CPU schedulers.

use std::sync::Arc;

use brd14_data::{Champ, Ns};
use rustler::types::binary::{Binary, OwnedBinary};
use rustler::{Atom, Encoder, Env, NifResult, ResourceArc, Term};

mod atoms {
    rustler::atoms! { ok, error, length, namespace, charset, range }
}

type Val = Arc<[u8]>;

pub struct ChampRes(Champ<Val>);

#[rustler::resource_impl]
impl rustler::Resource for ChampRes {}

fn class(e: brd14::Error) -> Atom {
    match e {
        brd14::Error::Length => atoms::length(),
        brd14::Error::Namespace => atoms::namespace(),
        brd14::Error::Charset => atoms::charset(),
        brd14::Error::Range => atoms::range(),
    }
}

fn bin<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut out = OwnedBinary::new(bytes.len()).expect("binary allocation");
    out.as_mut_slice().copy_from_slice(bytes);
    out.release(env).encode(env)
}

fn ns_of(b: &Binary) -> Option<Ns> {
    <[u8; 3]>::try_from(b.as_slice()).ok()
}

fn store(term: Term) -> Val {
    Arc::from(term.to_binary().as_slice())
}

fn load<'a>(env: Env<'a>, v: &Val) -> Term<'a> {
    env.binary_to_term(v).expect("a stored value is valid external term format").0
}

fn wrap(c: Champ<Val>) -> ResourceArc<ChampRes> {
    ResourceArc::new(ChampRes(c))
}

// ── codec ───────────────────────────────────────────────────────────────────

#[rustler::nif]
fn decode<'a>(env: Env<'a>, id: Binary<'a>) -> Term<'a> {
    match brd14::decode(id.as_slice()) {
        Ok((ns, snow)) => (bin(env, &ns), snow).encode(env),
        Err(_) => atoms::error().encode(env),
    }
}

#[rustler::nif]
fn decode_hash<'a>(env: Env<'a>, id: Binary<'a>) -> Term<'a> {
    match brd14::decode(id.as_slice()) {
        Ok((ns, snow)) => (bin(env, &ns), snow, brd14::hash32(snow)).encode(env),
        Err(_) => atoms::error().encode(env),
    }
}

#[rustler::nif]
fn encode<'a>(env: Env<'a>, ns: Binary<'a>, snow: u64) -> NifResult<Term<'a>> {
    let ns = ns_of(&ns).ok_or(rustler::Error::BadArg)?;
    Ok(match brd14::encode(&ns, snow) {
        Ok(id) => bin(env, &id),
        Err(_) => atoms::error().encode(env),
    })
}

#[rustler::nif]
fn hash32(snow: u64) -> u32 {
    brd14::hash32(snow)
}

// ── champ ───────────────────────────────────────────────────────────────────

#[rustler::nif]
fn champ_new() -> ResourceArc<ChampRes> {
    wrap(Champ::new())
}

#[rustler::nif]
fn champ_put<'a>(env: Env<'a>, c: ResourceArc<ChampRes>, id: Binary<'a>, value: Term<'a>) -> Term<'a> {
    match c.0.insert(id.as_slice(), store(value)) {
        Ok(next) => (atoms::ok(), wrap(next)).encode(env),
        Err(e) => (atoms::error(), class(e)).encode(env),
    }
}

#[rustler::nif]
fn champ_put_snow<'a>(env: Env<'a>, c: ResourceArc<ChampRes>, ns: Binary<'a>, snow: u64, value: Term<'a>) -> Term<'a> {
    let Some(ns) = ns_of(&ns) else {
        return (atoms::error(), atoms::namespace()).encode(env);
    };
    match c.0.insert_snow(&ns, snow, store(value)) {
        Ok(next) => (atoms::ok(), wrap(next)).encode(env),
        Err(e) => (atoms::error(), class(e)).encode(env),
    }
}

#[rustler::nif]
fn champ_get<'a>(env: Env<'a>, c: ResourceArc<ChampRes>, id: Binary<'a>) -> Term<'a> {
    match c.0.get(id.as_slice()) {
        Some(v) => (atoms::ok(), load(env, v)).encode(env),
        None => atoms::error().encode(env),
    }
}

#[rustler::nif]
fn champ_get_snow<'a>(env: Env<'a>, c: ResourceArc<ChampRes>, ns: Binary<'a>, snow: u64) -> Term<'a> {
    match ns_of(&ns).and_then(|ns| c.0.get_snow(&ns, snow)) {
        Some(v) => (atoms::ok(), load(env, v)).encode(env),
        None => atoms::error().encode(env),
    }
}

#[rustler::nif]
fn champ_delete<'a>(env: Env<'a>, c: ResourceArc<ChampRes>, id: Binary<'a>) -> Term<'a> {
    match c.0.remove(id.as_slice()) {
        Ok(next) => (atoms::ok(), wrap(next)).encode(env),
        Err(e) => (atoms::error(), class(e)).encode(env),
    }
}

#[rustler::nif]
fn champ_delete_snow(c: ResourceArc<ChampRes>, ns: Binary, snow: u64) -> ResourceArc<ChampRes> {
    match ns_of(&ns) {
        Some(ns) => wrap(c.0.remove_snow(&ns, snow)),
        None => c,
    }
}

#[rustler::nif]
fn champ_size(c: ResourceArc<ChampRes>) -> usize {
    c.0.len()
}

#[rustler::nif]
fn champ_namespace_size(c: ResourceArc<ChampRes>, ns: Binary) -> usize {
    ns_of(&ns).map_or(0, |ns| c.0.namespace_len(&ns))
}

#[rustler::nif]
fn champ_namespaces<'a>(env: Env<'a>, c: ResourceArc<ChampRes>) -> Vec<Term<'a>> {
    c.0.namespaces().map(|ns| bin(env, ns)).collect()
}

#[rustler::nif]
fn champ_digest(c: ResourceArc<ChampRes>, ns: Binary) -> NifResult<u64> {
    let ns = ns_of(&ns).ok_or(rustler::Error::BadArg)?;
    Ok(c.0.shape_digest(&ns))
}

/// `[{ns, snowflake, value}]` in champ order: namespaces ascending, each trie in traversal order.
#[rustler::nif(schedule = "DirtyCpu")]
fn champ_to_list<'a>(env: Env<'a>, c: ResourceArc<ChampRes>) -> Vec<Term<'a>> {
    c.0.iter().map(|(ns, snow, v)| (bin(env, ns), snow, load(env, v)).encode(env)).collect()
}

/// Builds a champ from `[{ns, snowflake, value}]`; `{:error, class}` on the first bad entry.
#[rustler::nif(schedule = "DirtyCpu")]
fn champ_from_list<'a>(env: Env<'a>, entries: Vec<(Binary<'a>, u64, Term<'a>)>) -> Term<'a> {
    let mut c = Champ::new();
    for (ns, snow, value) in entries {
        let Some(ns) = ns_of(&ns) else {
            return (atoms::error(), atoms::namespace()).encode(env);
        };
        match c.insert_snow(&ns, snow, store(value)) {
            Ok(next) => c = next,
            Err(e) => return (atoms::error(), class(e)).encode(env),
        }
    }
    (atoms::ok(), wrap(c)).encode(env)
}

rustler::init!("Elixir.EchoData.Native");
