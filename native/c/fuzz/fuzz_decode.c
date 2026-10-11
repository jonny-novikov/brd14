/* fuzz_decode.c — libFuzzer target: decode is total, and every core agrees.
 *
 *   make fuzz FUZZ_SECONDS=30
 *
 * The input is the id, any length, any bytes. libFuzzer hands over a heap
 * buffer of exactly that size and the build carries ASan + UBSan, so a core
 * that reads one byte past len, or past the 14 it may read, or overflows
 * anything, aborts the run. Properties, for every input:
 *
 *   totality      every core returns one of the five statuses, no crash, no UB
 *   differential  speed, memory, memory_noint128 and the reference model
 *                 (test/support.h) return the same status, namespace, value
 *   refusals      a refused decode leaves ns_out and *snowflake_out untouched
 *   round trip    on success, encode(ns, value) reproduces the input bytes
 *                 exactly, in every core (so decode accepts one spelling only)
 *
 * Outputs live in exact-size stack arrays, so ASan's redzones also catch a
 * core writing a fourth namespace byte or a fifteenth id byte.
 */
#include "branded_id.h"
#include "../test/cores.h"
#include "../test/support.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define SENTINEL 0xDEADBEEFDEADBEEFULL

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  char want_ns[BRANDED_NS_LEN] = {'#', '#', '#'};
  uint64_t want_v = SENTINEL;
  branded_status want = ref_decode(data, size, want_ns, &want_v);

  for (size_t c = 0; c < NCORES; c++) {
    char ns[BRANDED_NS_LEN] = {'#', '#', '#'};
    uint64_t v = SENTINEL;
    branded_status s = CORES[c].decode((const char *)data, size, ns, &v);
    if ((unsigned)s > 4u || s != want) abort();
    if (s != BRANDED_OK) {
      if (memcmp(ns, "###", 3) != 0 || v != SENTINEL) abort();
      continue;
    }
    if (memcmp(ns, want_ns, 3) != 0 || v != want_v) abort();
    char out[BRANDED_LEN];
    if (CORES[c].encode(ns, v, out) != BRANDED_OK || memcmp(out, data, BRANDED_LEN) != 0) abort();
  }
  return 0;
}
