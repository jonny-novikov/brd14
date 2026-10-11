/* branded_id.h — the branded Snowflake contract as a C ABI.
 *
 * Format:  3 x [A-Z] namespace ++ 11 x [0-9A-Za-z] base62(snowflake), 14 bytes fixed.
 * Range:   snowflake in [0, 2^63), layout ts(41) << 22 | node(10) << 12 | seq(12),
 *          epoch 2024-01-01T00:00:00Z (BRANDED_EPOCH_MS).
 *
 * Contract vectors (every implementation must pass):
 *   encode("USR", 274557032793636864)  -> "USR0KHTOWnGLuC"
 *   decode("USR0NgWEfAEJfs")           -> 320636799581945856
 *   branded_hash32(274557032793636864) -> 234878118
 *   decode payload "zzzzzzzzzzz"       -> BRANDED_ERR_RANGE   (62^11-1 > 2^63-1)
 */
#ifndef BRANDED_ID_H
#define BRANDED_ID_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define BRANDED_LEN          14
#define BRANDED_NS_LEN        3
#define BRANDED_PAYLOAD_LEN  11
#define BRANDED_EPOCH_MS     1704067200000ULL  /* 2024-01-01T00:00:00Z */

typedef enum {
  BRANDED_OK            = 0,
  BRANDED_ERR_LENGTH    = 1,  /* input is not exactly 14 bytes               */
  BRANDED_ERR_NAMESPACE = 2,  /* first 3 bytes are not [A-Z]                 */
  BRANDED_ERR_CHARSET   = 3,  /* payload byte outside [0-9A-Za-z]            */
  BRANDED_ERR_RANGE     = 4   /* value outside [0, 2^63)                     */
} branded_status;

/* Writes exactly BRANDED_LEN bytes to out; no NUL terminator is appended. */
branded_status branded_encode(const char ns[BRANDED_NS_LEN], uint64_t snowflake,
                              char out[BRANDED_LEN]);

/* Parses exactly len == BRANDED_LEN bytes; on success fills ns_out (3 bytes,
 * no NUL) and *snowflake_out (< 2^63). Validation order: length, namespace,
 * charset, range. */
branded_status branded_decode(const char *id, size_t len,
                              char ns_out[BRANDED_NS_LEN], uint64_t *snowflake_out);

/* Trie hash: the first half of MurmurHash3's fmix64 (xor-shift 33, multiply
 * by 0xFF51AFD7ED558CCD, xor-shift 33), truncated to the low 32 bits. */
uint32_t branded_hash32(uint64_t key);

/* Mint instant of the snowflake as Unix milliseconds. */
uint64_t branded_unix_ms(uint64_t snowflake);

#ifdef __cplusplus
}
#endif
#endif /* BRANDED_ID_H */
