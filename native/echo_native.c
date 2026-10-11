/* echo_native.c — the production NIF: codec + hash only, over the Rust core.
 * Loaded by EchoData.Native; absence is fine (pure Elixir fallback).
 * Build: make -C native    (writes priv/echo_native.so + priv/libbranded_rs.so)
 */
#include <erl_nif.h>
#include <stdint.h>
#include <string.h>

extern int      branded_encode(const char *ns, uint64_t snowflake, char *out);
extern int      branded_decode(const char *id, size_t len, char *ns_out, uint64_t *snowflake_out);
extern uint32_t branded_hash32(uint64_t key);

#define BRANDED_LEN 14
#define NS_LEN 3

static ERL_NIF_TERM atom_error;

static ERL_NIF_TERM nif_hash32(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifUInt64 key;
  if (!enif_get_uint64(env, argv[0], &key)) return enif_make_badarg(env);
  return enif_make_uint(env, branded_hash32(key));
}

static ERL_NIF_TERM nif_decode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary bin;
  char ns[NS_LEN]; uint64_t snow;
  if (!enif_inspect_binary(env, argv[0], &bin)) return enif_make_badarg(env);
  if (branded_decode((const char *)bin.data, bin.size, ns, &snow) != 0) return atom_error;
  ERL_NIF_TERM ns_term;
  memcpy(enif_make_new_binary(env, NS_LEN, &ns_term), ns, NS_LEN);
  return enif_make_tuple2(env, ns_term, enif_make_uint64(env, snow));
}

static ERL_NIF_TERM nif_decode_hash(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary bin;
  char ns[NS_LEN]; uint64_t snow;
  if (!enif_inspect_binary(env, argv[0], &bin)) return enif_make_badarg(env);
  if (branded_decode((const char *)bin.data, bin.size, ns, &snow) != 0) return atom_error;
  ERL_NIF_TERM ns_term;
  memcpy(enif_make_new_binary(env, NS_LEN, &ns_term), ns, NS_LEN);
  return enif_make_tuple3(env, ns_term, enif_make_uint64(env, snow),
                          enif_make_uint(env, branded_hash32(snow)));
}

static ERL_NIF_TERM nif_encode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary ns;
  ErlNifUInt64 snow;
  if (!enif_inspect_binary(env, argv[0], &ns) || ns.size != NS_LEN ||
      !enif_get_uint64(env, argv[1], &snow))
    return enif_make_badarg(env);
  char out[BRANDED_LEN];
  if (branded_encode((const char *)ns.data, snow, out) != 0) return atom_error;
  ERL_NIF_TERM id;
  memcpy(enif_make_new_binary(env, BRANDED_LEN, &id), out, BRANDED_LEN);
  return id;
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
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
