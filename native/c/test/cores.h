/* cores.h — every C core in one binary, for the differential programs
 * (test/test_props.c and the fuzz targets).
 *
 * Each core's shipped object is copied with its four ABI symbols renamed by
 * objcopy (Makefile: %/branded_id.ren.o), branded_encode ->
 * <core>_branded_encode and so on, so several cores link side by side and the
 * code under test is byte-for-byte the code that ships. memory_noint128 is
 * the memory source built with BRANDED_NO_INT128 (the portable mulhi path).
 */
#ifndef BRD14_C_TEST_CORES_H
#define BRD14_C_TEST_CORES_H

#include "branded_id.h"
#include "support.h"

#define BRD_DECLARE_CORE(p)                                                                \
  branded_status p##_branded_encode(const char ns[BRANDED_NS_LEN], uint64_t snowflake,      \
                                    char out[BRANDED_LEN]);                                 \
  branded_status p##_branded_decode(const char *id, size_t len, char ns_out[BRANDED_NS_LEN],  \
                                    uint64_t *snowflake_out);                               \
  uint32_t p##_branded_hash32(uint64_t key);                                                \
  uint64_t p##_branded_unix_ms(uint64_t snowflake);

BRD_DECLARE_CORE(speed)
BRD_DECLARE_CORE(memory)
BRD_DECLARE_CORE(memory_noint128)

typedef struct {
  const char *name;
  brd_encode_fn encode;
  brd_decode_fn decode;
  uint32_t (*hash32)(uint64_t);
  uint64_t (*unix_ms)(uint64_t);
} brd_core;

#define BRD_CORE(p) {#p, p##_branded_encode, p##_branded_decode, p##_branded_hash32, p##_branded_unix_ms}
static const brd_core CORES[] = {BRD_CORE(speed), BRD_CORE(memory), BRD_CORE(memory_noint128)};
#define NCORES (sizeof CORES / sizeof CORES[0])

#endif /* BRD14_C_TEST_CORES_H */
