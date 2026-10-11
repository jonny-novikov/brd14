/* conform.c — the parity shim for one C core (docs/contract.md, "Parity shim
 * protocol"). Built once per core: build/conform-speed, build/conform-memory.
 *
 *   tools/parity.py --only c-
 *
 * First line: "HELLO c <variant> EDHU". The ABI has no node derivation and
 * no field reader, so N and F are not declared and the driver never sends
 * them; any request this shim does not understand is a protocol error (stderr,
 * exit 2), never a guessed answer.
 *
 * E <ns_hex> <snow> with a namespace whose length is not 3 is answered
 * ERR NAMESPACE here, without calling the ABI: branded_encode takes exactly
 * 3 bytes and cannot see a length, so calling it would read past a shorter
 * buffer or accept the 3-byte prefix of a longer one ("USRR" as "USR"). The
 * contract puts that check on the caller, and this shim is a caller.
 *
 * <snow> in E and <k> in H may be anything in [0, 2^64), so both are parsed
 * as full u64 (strictly: digits only — strtoull would wrap "-1"). stdio runs
 * with 1 MiB buffers in both directions: the driver feeds ~150k requests
 * through files, and line-buffered output would cost a write(2) per answer.
 */
#include "branded_id.h"
#include "support.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef VARIANT
#define VARIANT "unknown"
#endif

#define LINE_MAX_BYTES (1u << 16)

static char in_buf[1u << 20], out_buf[1u << 20];
static char line[LINE_MAX_BYTES];
static unsigned char bytes[LINE_MAX_BYTES / 2u];

static unsigned long lineno;

static _Noreturn void protocol_error(const char *why) {
  fflush(stdout);
  fprintf(stderr, "conform c-%s: line %lu: %s\n", VARIANT, lineno, why);
  exit(2);
}

static void put_u64(uint64_t v) {
  char d[20];
  int n = 0;
  do {
    d[n++] = (char)('0' + v % 10u);
    v /= 10u;
  } while (v);
  while (n) putchar(d[--n]);
}

static void put_err(branded_status s) {
  fputs("ERR ", stdout);
  fputs(brd_class_name(s), stdout);
  putchar('\n');
}

static branded_status encode_abi(const char *ns, uint64_t snow, char *out) {
  return branded_encode(ns, snow, out);
}

/* Splits "OP a b" on single spaces; returns the argument count (max 2). */
static int args_of(char *s, size_t n, char *arg[2], size_t len[2]) {
  if (n < 2 || s[1] != ' ') return n == 1 ? 0 : -1;
  int k = 0;
  size_t i = 2;
  while (i <= n) {
    if (k == 2) return -1;
    size_t j = i;
    while (j < n && s[j] != ' ') j++;
    if (j == i) return -1; /* empty field */
    arg[k] = s + i;
    len[k] = j - i;
    k++;
    i = j + 1;
  }
  return k;
}

int main(void) {
  setvbuf(stdin, in_buf, _IOFBF, sizeof in_buf);
  setvbuf(stdout, out_buf, _IOFBF, sizeof out_buf);
  printf("HELLO c %s EDHU\n", VARIANT);

  while (fgets(line, sizeof line, stdin)) {
    lineno++;
    size_t n = strlen(line);
    if (n && line[n - 1] == '\n') line[--n] = '\0';
    else if (!feof(stdin)) protocol_error("request line too long");
    if (n && line[n - 1] == '\r') line[--n] = '\0';
    if (n == 0) continue;

    char *arg[2];
    size_t len[2];
    int nargs = args_of(line, n, arg, len);
    uint64_t v;
    switch (line[0]) {
      case 'E': {
        if (nargs != 2) protocol_error("E takes <ns_hex> <snow>");
        long ns_len = brd_unhex(arg[0], len[0], bytes, sizeof bytes);
        if (ns_len < 0) protocol_error("bad hex");
        if (!brd_parse_u64(arg[1], len[1], &v)) protocol_error("bad <snow>");
        char out[BRANDED_LEN];
        branded_status s = brd_encode_bytes(encode_abi, bytes, (size_t)ns_len, v, out);
        if (s != BRANDED_OK) {
          put_err(s);
        } else {
          fputs("OK ", stdout);
          fwrite(out, 1, BRANDED_LEN, stdout);
          putchar('\n');
        }
        break;
      }
      case 'D': {
        if (nargs != 1) protocol_error("D takes <id_hex>");
        long id_len = brd_unhex(arg[0], len[0], bytes, sizeof bytes);
        if (id_len < 0) protocol_error("bad hex");
        char ns[BRANDED_NS_LEN];
        branded_status s = branded_decode((const char *)bytes, (size_t)id_len, ns, &v);
        if (s != BRANDED_OK) {
          put_err(s);
        } else {
          fputs("OK ", stdout);
          fwrite(ns, 1, BRANDED_NS_LEN, stdout);
          putchar(' ');
          put_u64(v);
          putchar('\n');
        }
        break;
      }
      case 'H':
        if (nargs != 1 || !brd_parse_u64(arg[0], len[0], &v)) protocol_error("H takes <k>");
        fputs("OK ", stdout);
        put_u64(branded_hash32(v));
        putchar('\n');
        break;
      case 'U':
        if (nargs != 1 || !brd_parse_u64(arg[0], len[0], &v)) protocol_error("U takes <snow>");
        fputs("OK ", stdout);
        put_u64(branded_unix_ms(v));
        putchar('\n');
        break;
      default:
        protocol_error("unsupported request (this shim declares EDHU)");
    }
  }
  if (ferror(stdin)) protocol_error("read error");
  if (fflush(stdout) != 0 || ferror(stdout)) {
    fprintf(stderr, "conform c-%s: write error\n", VARIANT);
    return 2;
  }
  return 0;
}
