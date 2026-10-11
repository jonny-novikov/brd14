/* stub/erl_nif.h — NOT the Erlang/OTP header. CI SYNTAX CHECK ONLY.
 *
 * `make check` uses this file only when no ERTS installation is found, so
 * that echo_native.c can still be compiled (syntax, types, warnings) on a
 * machine without Erlang. It declares exactly the subset echo_native.c
 * uses, with the shapes of the real API on LP64 (ERL_NIF_TERM and
 * ErlNifUInt64 are unsigned long there). It is not ABI-compatible with ERTS:
 * the ErlNifEntry below is a placeholder, so a NIF built against this file
 * must never be loaded. `make all` refuses to build without real headers.
 */
#ifndef BRD14_STUB_ERL_NIF_H
#define BRD14_STUB_ERL_NIF_H

#include <stddef.h>

typedef unsigned long ERL_NIF_TERM;
typedef unsigned long ErlNifUInt64;
typedef struct enif_environment_t ErlNifEnv;

typedef struct {
  size_t size;
  unsigned char *data;
  void *ref_bin;
  void *spare[2];
} ErlNifBinary;

typedef struct {
  const char *name;
  unsigned arity;
  ERL_NIF_TERM (*fptr)(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
  unsigned flags;
} ErlNifFunc;

typedef struct {
  const char *name;
  int num_of_funcs;
  ErlNifFunc *funcs;
  int (*load)(ErlNifEnv *, void **priv_data, ERL_NIF_TERM load_info);
  int (*reload)(ErlNifEnv *, void **priv_data, ERL_NIF_TERM load_info);
  int (*upgrade)(ErlNifEnv *, void **priv_data, void **old_priv_data, ERL_NIF_TERM load_info);
  void (*unload)(ErlNifEnv *, void *priv_data);
} ErlNifEntry;

int enif_get_uint64(ErlNifEnv *env, ERL_NIF_TERM term, ErlNifUInt64 *ip);
int enif_inspect_binary(ErlNifEnv *env, ERL_NIF_TERM bin_term, ErlNifBinary *bin);
ERL_NIF_TERM enif_make_badarg(ErlNifEnv *env);
ERL_NIF_TERM enif_make_uint(ErlNifEnv *env, unsigned i);
ERL_NIF_TERM enif_make_uint64(ErlNifEnv *env, ErlNifUInt64 i);
ERL_NIF_TERM enif_make_atom(ErlNifEnv *env, const char *name);
ERL_NIF_TERM enif_make_tuple2(ErlNifEnv *env, ERL_NIF_TERM e1, ERL_NIF_TERM e2);
ERL_NIF_TERM enif_make_tuple3(ErlNifEnv *env, ERL_NIF_TERM e1, ERL_NIF_TERM e2, ERL_NIF_TERM e3);
unsigned char *enif_make_new_binary(ErlNifEnv *env, size_t size, ERL_NIF_TERM *termp);

/* The real macro also records the ERTS version, VM variant and options. */
#define ERL_NIF_INIT(NAME, FUNCS, LOAD, RELOAD, UPGRADE, UNLOAD)                         \
  ErlNifEntry *nif_init(void);                                                           \
  ErlNifEntry *nif_init(void) {                                                          \
    static ErlNifEntry entry = {#NAME, (int)(sizeof(FUNCS) / sizeof((FUNCS)[0])), FUNCS, \
                                LOAD, RELOAD, UPGRADE, UNLOAD};                          \
    return &entry;                                                                       \
  }

#endif /* BRD14_STUB_ERL_NIF_H */
