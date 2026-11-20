/*
 * test_smoke - M0: the tape library builds and links, and the ROM timing
 * table holds the documented values. Real encoder/decoder tests come in M1a.
 */
#include <stdio.h>
#include "tape.h"

static int failures;

#define CHECK(cond)                                                     \
    do {                                                                \
        if (!(cond)) {                                                  \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n",                \
                    __FILE__, __LINE__, #cond);                         \
            failures++;                                                 \
        }                                                               \
    } while (0)

int main(void)
{
    const tape_timing_t *tm = &tape_timing_rom;

    CHECK(tm->pilot == 2168);
    CHECK(tm->sync1 == 667);
    CHECK(tm->sync2 == 735);
    CHECK(tm->zero == 855);
    CHECK(tm->one == 1710);
    CHECK(tm->pilot_header == 8063);
    CHECK(tm->pilot_data == 3223);

    /* Every entry point links. */
    uint8_t buf[4] = {0};
    tape_enc_t e;
    tape_pulse_t p;
    tape_enc_init(&e, tm, buf, sizeof buf);
    (void)tape_enc_next(&e, &p);

    tape_dec_t d;
    tape_dec_init(&d, buf, sizeof buf);
    (void)tape_dec_feed(&d, 2168);
    (void)tape_dec_end(&d);

    tapfile_reader_t r;
    const uint8_t *blk;
    size_t len;
    tapfile_reader_init(&r, buf, sizeof buf);
    (void)tapfile_next(&r, &blk, &len);
    (void)tapfile_write_block(buf, sizeof buf, buf, 0);
    (void)tape_checksum(buf, sizeof buf);
    (void)tape_make_block(0xFF, buf, 0, buf, sizeof buf);

    if (failures == 0)
        printf("smoke: OK\n");
    return failures ? 1 : 0;
}
