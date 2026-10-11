/* echo_native.c — the production NIF: codec + hash only, over one brd14 core.
 * Loaded by EchoData.Native; absence is fine (pure Elixir fallback).
 *
 * The core is chosen at build time and only behind the C ABI in
 * branded_id.h, so this file is identical for every core:
 *   make                 CORE=rust      the Rust FFI drop-in (libbrd14_ffi.so)
 *   make CORE=c-speed    the C speed core, compiled into the NIF
 *   make CORE=c-memory   the C memory core, compiled into the NIF
 * See docs/beam.md.
 *
 * Error classes collapse to the atom :error. The cores distinguish LENGTH,
 * NAMESPACE, CHARSET and RANGE (docs/contract.md); the Elixir API this NIF
 * backs returns {:ok, _} | :error, so the class is not surfaced here.
 * Argument-type mistakes (not a binary, not a u64, a namespace that is not
 * exactly 3 bytes) raise badarg instead, as before.
 *
 * Every function is a few dozen nanoseconds of pure computation on a
 * caller-owned buffer — far below the ~1 ms budget for a NIF on a normal
 * scheduler — so none needs a dirty scheduler or yielding.
 */
#include <erl_nif.h>
#include <stdint.h>
#include <string.h>

#include "branded_id.h"

static ERL_NIF_TERM atom_error;

static ERL_NIF_TERM nif_hash32(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  ErlNifUInt64 key;
  if (!enif_get_uint64(env, argv[0], &key)) return enif_make_badarg(env);
  return enif_make_uint(env, branded_hash32(key));
}

static ERL_NIF_TERM nif_decode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  ErlNifBinary bin;
  char ns[BRANDED_NS_LEN];
  uint64_t snow;
  if (!enif_inspect_binary(env, argv[0], &bin)) return enif_make_badarg(env);
  if (branded_decode((const char *)bin.data, bin.size, ns, &snow) != BRANDED_OK) return atom_error;
  ERL_NIF_TERM ns_term;
  memcpy(enif_make_new_binary(env, BRANDED_NS_LEN, &ns_term), ns, BRANDED_NS_LEN);
  return enif_make_tuple2(env, ns_term, enif_make_uint64(env, snow));
}

static ERL_NIF_TERM nif_decode_hash(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  ErlNifBinary bin;
  char ns[BRANDED_NS_LEN];
  uint64_t snow;
  if (!enif_inspect_binary(env, argv[0], &bin)) return enif_make_badarg(env);
  if (branded_decode((const char *)bin.data, bin.size, ns, &snow) != BRANDED_OK) return atom_error;
  ERL_NIF_TERM ns_term;
  memcpy(enif_make_new_binary(env, BRANDED_NS_LEN, &ns_term), ns, BRANDED_NS_LEN);
  return enif_make_tuple3(env, ns_term, enif_make_uint64(env, snow),
                          enif_make_uint(env, branded_hash32(snow)));
}

static ERL_NIF_TERM nif_encode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  ErlNifBinary ns;
  ErlNifUInt64 snow;
  /* The ABI takes exactly 3 namespace bytes and cannot see a length, so the
   * length is checked here, before the call (badarg, as it always was). */
  if (!enif_inspect_binary(env, argv[0], &ns) || ns.size != BRANDED_NS_LEN ||
      !enif_get_uint64(env, argv[1], &snow))
    return enif_make_badarg(env);
  char out[BRANDED_LEN];
  if (branded_encode((const char *)ns.data, snow, out) != BRANDED_OK) return atom_error;
  ERL_NIF_TERM id;
  memcpy(enif_make_new_binary(env, BRANDED_LEN, &id), out, BRANDED_LEN);
  return id;
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
  (void)priv;
  (void)info;
  atom_error = enif_make_atom(env, "error");
  return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"hash32", 1, nif_hash32, 0},
    {"decode", 1, nif_decode, 0},
    {"decode_hash", 1, nif_decode_hash, 0},
    {"encode", 2, nif_encode, 0},
};

ERL_NIF_INIT(Elixir.EchoData.Native, nif_funcs, load, NULL, NULL, NULL)
