/* fuzz_encode.c — libFuzzer target: encode differential on (ns, u64).
 *
 *   make fuzz FUZZ_SECONDS=30
 *
 * Input layout: bytes 0..2 are the namespace exactly as the fixed-width ABI
 * takes it, bytes 3..10 the snowflake as a little-endian u64 (any value in
 * [0, 2^64), so RANGE and the precedence of NAMESPACE over it are fuzzed
 * too); a shorter input is zero-padded, a longer one's tail is ignored.
 * Properties, for every input:
 *
 *   differential  speed, memory, memory_noint128 and the reference model
 *                 return the same status and, on success, the same 14 bytes
 *   precedence    a bad namespace is NAMESPACE whatever the value
 *   refusals      a refused encode leaves out untouched
 *   round trip    on success every core decodes the id back to (ns, value)
 *   readers       hash32 and unix_ms agree with the reference on the full u64
 *
 * The namespace and the output live in exact-size stack arrays, so ASan
 * catches a core reading a fourth namespace byte or writing a fifteenth.
 */
#include "branded_id.h"
#include "../test/cores.h"
#include "../test/support.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  unsigned char in[BRANDED_NS_LEN + 8] = {0};
  memcpy(in, data, size < sizeof in ? size : sizeof in);
  unsigned char ns[BRANDED_NS_LEN] = {in[0], in[1], in[2]};
  uint64_t snow = 0;
  for (int i = 0; i < 8; i++) snow |= (uint64_t)in[BRANDED_NS_LEN + i] << (8 * i);

  char want[BRANDED_LEN];
  memset(want, '#', sizeof want);
  branded_status ws = ref_encode(ns, BRANDED_NS_LEN, snow, want);
  int ns_ok = ref_upper(ns[0]) && ref_upper(ns[1]) && ref_upper(ns[2]);
  if (!ns_ok && ws != BRANDED_ERR_NAMESPACE) abort(); /* the reference itself */

  uint32_t want_h = ref_hash32(snow);
  uint64_t want_ms = (snow >> 22) + BRANDED_EPOCH_MS;

  for (size_t c = 0; c < NCORES; c++) {
    if (CORES[c].hash32(snow) != want_h || CORES[c].unix_ms(snow) != want_ms) abort();
    char out[BRANDED_LEN];
    memset(out, '#', sizeof out);
    branded_status s = CORES[c].encode((const char *)ns, snow, out);
    if (s != ws) abort();
    if (s != BRANDED_OK) {
      if (memcmp(out, "##############", BRANDED_LEN) != 0) abort();
      continue;
    }
    if (memcmp(out, want, BRANDED_LEN) != 0) abort();
    for (size_t d = 0; d < NCORES; d++) {
      char back_ns[BRANDED_NS_LEN];
      uint64_t back = 0;
      if (CORES[d].decode(out, BRANDED_LEN, back_ns, &back) != BRANDED_OK) abort();
      if (back != snow || memcmp(back_ns, ns, BRANDED_NS_LEN) != 0) abort();
    }
  }
  return 0;
}
