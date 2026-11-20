/*
 * test_testtape - the firmware's PLAY test tape (esp32/main/testtape.c) is a
 * well-formed .tap: a 17-byte program header and a BASIC data block whose
 * line lengths add up. With argv[1], also writes it out to load in an
 * emulator.
 */
#include <stdio.h>
#include <string.h>
#include "tape.h"
#include "testtape.h"

static int failures;

#define CHECK(cond)                                                     \
    do {                                                                \
        if (!(cond)) {                                                  \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n",                \
                    __FILE__, __LINE__, #cond);                         \
            failures++;                                                 \
        }                                                               \
    } while (0)

int main(int argc, char **argv)
{
    uint8_t tap[256];
    size_t n = testtape_build(tap, sizeof tap), len, plen, pos;
    const uint8_t *hdr, *data;
    tapfile_reader_t r;

    CHECK(n > 0);
    tapfile_reader_init(&r, tap, n);
    CHECK(tapfile_next(&r, &hdr, &len) == 1 && len == 19);
    CHECK(hdr[0] == 0x00 && hdr[1] == 0 && tape_checksum(hdr, len) == 0);
    CHECK(memcmp(hdr + 2, "ZXMODEM   ", 10) == 0);
    CHECK((hdr[14] | hdr[15] << 8) == 10);             /* autostart line */
    plen = hdr[12] | hdr[13] << 8;
    CHECK((size_t)(hdr[16] | hdr[17] << 8) == plen);           /* no variables */

    CHECK(tapfile_next(&r, &data, &len) == 1 && len == plen + 2);
    CHECK(data[0] == 0xFF && tape_checksum(data, len) == 0);
    CHECK(tapfile_next(&r, &data, &len) == 0);

    /* Walk the lines: number, length, body ending in 0x0D. */
    tapfile_reader_init(&r, tap, n);
    tapfile_next(&r, &hdr, &len);
    tapfile_next(&r, &data, &len);
    const uint8_t *p = data + 1;
    int lines = 0, last = 0;
    for (pos = 0; pos + 4 <= plen; lines++) {
        int num = p[pos] << 8 | p[pos + 1];
        size_t ll = p[pos + 2] | p[pos + 3] << 8;
        CHECK(num > last);
        last = num;
        CHECK(pos + 4 + ll <= plen && p[pos + 4 + ll - 1] == 0x0D);
        pos += 4 + ll;
    }
    CHECK(pos == plen && lines == 4);

    if (argc > 1) {
        FILE *f = fopen(argv[1], "wb");
        CHECK(f && fwrite(tap, 1, n, f) == n);
        if (f)
            fclose(f);
    }
    if (failures == 0)
        printf("testtape: OK (%u-byte program, %d lines)\n", (unsigned)plen, lines);
    return failures ? 1 : 0;
}
