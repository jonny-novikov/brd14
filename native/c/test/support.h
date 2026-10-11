/* support.h — shared by the C tests, the parity shim, the bench and the fuzz
 * targets. Header-only (static functions) so each program links exactly one
 * or more core objects plus its own translation unit, nothing else.
 *
 * Contents:
 *   brd_class[]        status -> the contract's class name ("NAMESPACE", ...)
 *   brd_encode_bytes   the caller-level wrapper for variable-length namespaces
 *   brd_parse_u64      strict unsigned decimal, the full [0, 2^64) range
 *   brd_unhex          lowercase/uppercase hex, '-' = empty (vectors schema)
 *   brd_splitmix64     the language-neutral stream of tools/oracle.py
 *   ref_encode/decode  a naive reference model, written like the oracle
 */
#ifndef BRD14_C_TEST_SUPPORT_H
#define BRD14_C_TEST_SUPPORT_H

#include "branded_id.h"
#include <stddef.h>
#include <stdint.h>
#include <string.h>

static const char *const brd_class[] = {"OK", "LENGTH", "NAMESPACE", "CHARSET", "RANGE"};

static inline const char *brd_class_name(branded_status s) {
  return (unsigned)s < 5u ? brd_class[s] : "UNKNOWN";
}

typedef branded_status (*brd_encode_fn)(const char *ns, uint64_t snowflake, char *out);
typedef branded_status (*brd_decode_fn)(const char *id, size_t len, char *ns_out,
                                        uint64_t *snowflake_out);

/* encode over a namespace of any length. The ABI takes exactly 3 bytes and
 * cannot see a length, so a namespace of any other length is refused here as
 * NAMESPACE (docs/contract.md: "a fixed-width ABI that cannot see the length
 * leaves that check to its caller"). Calling the ABI instead would read past
 * a shorter buffer, or silently accept the 3-byte prefix of a longer one. */
static inline branded_status brd_encode_bytes(brd_encode_fn enc, const unsigned char *ns,
                                              size_t ns_len, uint64_t snowflake,
                                              char out[BRANDED_LEN]) {
  if (ns_len != BRANDED_NS_LEN) return BRANDED_ERR_NAMESPACE;
  return enc((const char *)ns, snowflake, out);
}

/* Strict decimal: digits only (no sign, no space, no base prefix — strtoull
 * would accept "-1" and wrap it), at least one digit, no overflow past
 * 2^64 - 1. Returns 1 on success. */
static inline int brd_parse_u64(const char *s, size_t n, uint64_t *out) {
  if (n == 0 || n > 20) return 0;
  uint64_t v = 0;
  for (size_t i = 0; i < n; i++) {
    unsigned d = (unsigned)(unsigned char)s[i] - (unsigned)'0';
    if (d > 9u) return 0;
    if (v > (UINT64_MAX - d) / 10u) return 0;
    v = v * 10u + d;
  }
  *out = v;
  return 1;
}

static inline int brd_hexval(unsigned char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

/* Hex as the vectors and the parity protocol write it; "-" is the empty
 * string. Returns the byte count, or -1 on malformed input or overflow. */
static inline long brd_unhex(const char *s, size_t n, unsigned char *out, size_t cap) {
  if (n == 1 && s[0] == '-') return 0;
  if (n % 2u != 0u || n / 2u > cap) return -1;
  for (size_t i = 0; i < n / 2u; i++) {
    int h = brd_hexval((unsigned char)s[2u * i]), l = brd_hexval((unsigned char)s[2u * i + 1u]);
    if (h < 0 || l < 0) return -1;
    out[i] = (unsigned char)(h << 4 | l);
  }
  return (long)(n / 2u);
}

/* splitmix64 (Steele, Lea & Flood 2014), bit-identical to tools/oracle.py. */
static inline uint64_t brd_splitmix64(uint64_t *state) {
  uint64_t z = (*state += 0x9E3779B97F4A7C15ULL);
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
  return z ^ (z >> 31);
}

/* ── the reference model ─────────────────────────────────────────────────
 * Written the way tools/oracle.py is: one digit per u64 divmod by 62, a linear
 * alphabet search, and an overflow-checked Horner sum as the range guard. It
 * shares no technique with either core (no split, no table, no lexicographic
 * or (QA, RB) guard), so agreement with it is evidence, not echo. */
static const char BRD_ALPHABET[] = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
#define BRD_MAX_SNOW ((uint64_t)INT64_MAX)

static inline int ref_digit(unsigned char c) {
  for (int i = 0; i < 62; i++)
    if ((unsigned char)BRD_ALPHABET[i] == c) return i;
  return -1;
}

static inline int ref_upper(unsigned char c) { return c >= 'A' && c <= 'Z'; }

static inline branded_status ref_encode(const unsigned char *ns, size_t ns_len, uint64_t snow,
                                        char out[BRANDED_LEN]) {
  if (ns_len != 3 || !ref_upper(ns[0]) || !ref_upper(ns[1]) || !ref_upper(ns[2]))
    return BRANDED_ERR_NAMESPACE;
  if (snow > BRD_MAX_SNOW) return BRANDED_ERR_RANGE;
  memcpy(out, ns, 3);
  for (int i = BRANDED_LEN - 1; i >= BRANDED_NS_LEN; i--) {
    out[i] = BRD_ALPHABET[snow % 62u];
    snow /= 62u;
  }
  return BRANDED_OK;
}

static inline branded_status ref_decode(const unsigned char *id, size_t len, char ns_out[3],
                                        uint64_t *snow_out) {
  if (len != BRANDED_LEN) return BRANDED_ERR_LENGTH;
  if (!ref_upper(id[0]) || !ref_upper(id[1]) || !ref_upper(id[2])) return BRANDED_ERR_NAMESPACE;
  for (size_t i = BRANDED_NS_LEN; i < BRANDED_LEN; i++)
    if (ref_digit(id[i]) < 0) return BRANDED_ERR_CHARSET;
  uint64_t v = 0;
  for (size_t i = BRANDED_NS_LEN; i < BRANDED_LEN; i++) {
    uint64_t d = (uint64_t)ref_digit(id[i]);
    if (v > (BRD_MAX_SNOW - d) / 62u) return BRANDED_ERR_RANGE;
    v = v * 62u + d;
  }
  memcpy(ns_out, id, 3);
  *snow_out = v;
  return BRANDED_OK;
}

static inline uint32_t ref_hash32(uint64_t k) {
  k ^= k >> 33;
  k *= 0xFF51AFD7ED558CCDULL;
  k ^= k >> 33;
  return (uint32_t)(k & 0xFFFFFFFFu);
}

#endif /* BRD14_C_TEST_SUPPORT_H */
