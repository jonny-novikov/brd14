/* dropin.c — proves libbrd14_ffi is a drop-in for the C cores: compiled against the
 * unchanged native/include/branded_id.h and linked against libbrd14_ffi.a (static) or
 * libbrd14_ffi.so (shared), it must pass the contract vectors and the precedence rules.
 *
 *   make -C native/rust ffi-check
 */
#include "branded_id.h"

#include <stdio.h>
#include <string.h>

static int failures;

#define CHECK(cond)                                                       \
  do {                                                                    \
    if (!(cond)) {                                                        \
      fprintf(stderr, "dropin: FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
      failures++;                                                         \
    }                                                                     \
  } while (0)

static branded_status dec(const char *id, size_t len, char ns[3], uint64_t *snow) {
  return branded_decode(id, len, ns, snow);
}

int main(void) {
  char out[BRANDED_LEN];
  char ns[BRANDED_NS_LEN];
  uint64_t snow = 0;

  /* V-1 */
  CHECK(branded_encode("USR", 274557032793636864ULL, out) == BRANDED_OK);
  CHECK(memcmp(out, "USR0KHTOWnGLuC", BRANDED_LEN) == 0);
  CHECK(dec("USR0KHTOWnGLuC", 14, ns, &snow) == BRANDED_OK);
  CHECK(snow == 274557032793636864ULL && memcmp(ns, "USR", 3) == 0);
  /* V-2 */
  CHECK(dec("USR0NgWEfAEJfs", 14, ns, &snow) == BRANDED_OK);
  CHECK(snow == 320636799581945856ULL);
  /* V-3, V-4 */
  CHECK(branded_encode("ABC", 0, out) == BRANDED_OK && memcmp(out, "ABC00000000000", 14) == 0);
  CHECK(branded_encode("ABC", 9223372036854775807ULL, out) == BRANDED_OK);
  CHECK(memcmp(out + 3, "AzL8n0Y58m7", 11) == 0);
  /* V-5 */
  CHECK(dec("USRzzzzzzzzzzz", 14, ns, &snow) == BRANDED_ERR_RANGE);
  CHECK(dec("USRAzL8n0Y58m8", 14, ns, &snow) == BRANDED_ERR_RANGE);
  CHECK(dec("usr0KHTOWnGLuC", 14, ns, &snow) == BRANDED_ERR_NAMESPACE);
  CHECK(dec("USR0KHTOWnGLu", 13, ns, &snow) == BRANDED_ERR_LENGTH);
  CHECK(dec("USR0KHTOWnGLuCC", 15, ns, &snow) == BRANDED_ERR_LENGTH);
  /* V-6, E-1, E-2 */
  CHECK(branded_hash32(274557032793636864ULL) == 234878118u);
  CHECK(branded_unix_ms(274557032793636864ULL) == 1769526697641ULL);
  CHECK(branded_unix_ms(320636799581945856ULL) == 1780512970164ULL);
  /* precedence, namespace-first in both directions */
  CHECK(branded_encode("usr", 9223372036854775808ULL, out) == BRANDED_ERR_NAMESPACE);
  CHECK(dec("usr0KHTOWnGL!!", 14, ns, &snow) == BRANDED_ERR_NAMESPACE);
  CHECK(dec("USRzzzzzzzzzz!", 14, ns, &snow) == BRANDED_ERR_CHARSET);

  if (failures) return 1;
  puts("dropin: ok (V-1..V-6, E-1, E-2, precedence)");
  return 0;
}
