/* testtape.c - builds the test tape the PLAY button sends: an auto-running
 * BASIC program, as a header block and a data block.
 *
 *   10 BORDER 1: PRINT "ZX MODEM: LOAD OK"
 *   20 PRINT "SAVING 32 ROM BYTES"
 *   30 SAVE "REPLY" CODE 0,32
 *   40 PRINT "SAVED": GO TO 20
 *
 * So one test covers both directions: the LOAD proves ESP32 -> EAR, and the
 * SAVE of the first 32 ROM bytes (known values) proves MIC -> ESP32.
 * Plain C on purpose: the host tests build it too.
 */
#include <string.h>
#include "tape.h"
#include "testtape.h"

enum { T_CODE = 0xAF, T_BORDER = 0xE7, T_GO_TO = 0xEC, T_PRINT = 0xF5, T_SAVE = 0xF8 };

const uint8_t testtape_rom_start[8] = { 0xF3, 0xAF, 0x11, 0xFF, 0xFF, 0xC3, 0xCB, 0x11 };

typedef struct {
    uint8_t *p;
    size_t n;
} emit_t;

static void put(emit_t *e, uint8_t b)
{
    e->p[e->n++] = b;
}

static void str(emit_t *e, const char *s)
{
    while (*s)
        put(e, (uint8_t)*s++);
}

static void quoted(emit_t *e, const char *s)
{
    put(e, '"');
    str(e, s);
    put(e, '"');
}

/* A number literal: its digits, then 0x0E and the hidden 5-byte integer form
 * (00, sign 00, value LE, 00) that the ROM actually uses at run time. */
static void num(emit_t *e, uint16_t v)
{
    char d[6];
    int i = 5;
    uint16_t x = v;

    d[5] = 0;
    do {
        d[--i] = (char)('0' + x % 10);
        x /= 10;
    } while (x);
    str(e, d + i);
    put(e, 0x0E);
    put(e, 0);
    put(e, 0);
    put(e, (uint8_t)v);
    put(e, (uint8_t)(v >> 8));
    put(e, 0);
}

/* Line header: number (big-endian), length of the rest (little-endian),
 * then the body and 0x0D. begin/end wrap the body. */
static size_t begin(emit_t *e, uint16_t line)
{
    put(e, (uint8_t)(line >> 8));
    put(e, (uint8_t)line);
    e->n += 2;                              /* length, filled in by end() */
    return e->n;
}

static void end(emit_t *e, size_t body)
{
    put(e, 0x0D);
    e->p[body - 2] = (uint8_t)(e->n - body);
    e->p[body - 1] = (uint8_t)((e->n - body) >> 8);
}

static size_t program(uint8_t *p)
{
    emit_t e = { p, 0 };
    size_t b;

    b = begin(&e, 10);
    put(&e, T_BORDER); num(&e, 1); put(&e, ':');
    put(&e, T_PRINT); quoted(&e, "ZX MODEM: LOAD OK");
    end(&e, b);

    b = begin(&e, 20);
    put(&e, T_PRINT); quoted(&e, "SAVING 32 ROM BYTES");
    end(&e, b);

    b = begin(&e, 30);
    put(&e, T_SAVE); quoted(&e, "REPLY"); put(&e, T_CODE);
    num(&e, 0); put(&e, ','); num(&e, 32);
    end(&e, b);

    b = begin(&e, 40);
    put(&e, T_PRINT); quoted(&e, "SAVED"); put(&e, ':');
    put(&e, T_GO_TO); num(&e, 20);
    end(&e, b);
    return e.n;
}

size_t testtape_build(uint8_t *out, size_t cap)
{
    uint8_t prog[160], hdr[17], blk[sizeof prog + 2];
    size_t plen = program(prog), n, len;

    /* Header: type 0 (program), 10-char name, data length, autostart line,
     * program length (no variables). */
    hdr[0] = 0;
    memcpy(hdr + 1, "ZXMODEM   ", 10);
    hdr[11] = (uint8_t)plen;
    hdr[12] = (uint8_t)(plen >> 8);
    hdr[13] = 10;
    hdr[14] = 0;
    hdr[15] = (uint8_t)plen;
    hdr[16] = (uint8_t)(plen >> 8);

    len = tape_make_block(0x00, hdr, sizeof hdr, blk, sizeof blk);
    n = tapfile_write_block(out, cap, blk, len);
    len = tape_make_block(0xFF, prog, plen, blk, sizeof blk);
    if (n == 0 || len == 0)
        return 0;
    len = tapfile_write_block(out + n, cap - n, blk, len);
    return len ? n + len : 0;
}
