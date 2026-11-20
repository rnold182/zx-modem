/*
 * test_tape - encoder/decoder round trips, and decoding a real recording of
 * a 48K SAVE (data/zx48k-save-test.wav, passed as argv[1]).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

/* Encode one block and decode it again, stretching every pulse by
 * (1 + skew) and alternating +/- jitter T-states. */
static void round_trip(uint8_t flag, size_t n, double skew, int jitter)
{
    uint8_t payload[300], blk[302], out[302];
    size_t len, i;
    tape_enc_t e;
    tape_pulse_t p;
    tape_dec_t d;
    int events = 0, sign = 1;
    tape_dec_event_t ev;

    for (i = 0; i < n; i++)
        payload[i] = (uint8_t)(i * 37 + 5);
    len = tape_make_block(flag, payload, n, blk, sizeof blk);
    CHECK(len == n + 2);
    CHECK(tape_checksum(blk, len) == 0);

    tape_enc_init(&e, &tape_timing_rom, blk, len);
    tape_dec_init(&d, out, sizeof out);
    while (tape_enc_next(&e, &p)) {
        uint32_t t = (uint32_t)(p.tstates * (1.0 + skew)) + sign * jitter;
        sign = -sign;
        ev = tape_dec_feed(&d, t);
        if (ev != TAPE_DEC_NONE) {
            events++;
            CHECK(ev == TAPE_DEC_BLOCK_OK);
            CHECK(d.len == len);
            CHECK(memcmp(out, blk, len) == 0);
        }
    }
    CHECK(tape_dec_end(&d) == TAPE_DEC_NONE);
    CHECK(events == 1);
}

/* A Spectrum leaves the last half-pulse unterminated: drop the pause and
 * the final pulse, then end the input. */
static void unterminated_tail(void)
{
    uint8_t payload[4] = {0x12, 0x34, 0x56, 0x79}, blk[6], out[8];
    tape_enc_t e;
    tape_pulse_t p, pulses[20000];
    tape_dec_t d;
    size_t np = 0, i, len = tape_make_block(0xFF, payload, 4, blk, sizeof blk);
    tape_dec_event_t ev = TAPE_DEC_NONE;

    tape_enc_init(&e, &tape_timing_rom, blk, len);
    while (tape_enc_next(&e, &p))
        pulses[np++] = p;
    tape_dec_init(&d, out, sizeof out);
    for (i = 0; i + 2 < np; i++)        /* all but the last data pulse + pause */
        CHECK(tape_dec_feed(&d, pulses[i].tstates) == TAPE_DEC_NONE);
    ev = tape_dec_end(&d);
    CHECK(ev == TAPE_DEC_BLOCK_OK);
    CHECK(d.len == len && memcmp(out, blk, len) == 0);
}

static void tapfile(void)
{
    uint8_t a[3] = {1, 2, 3}, img[16];
    const uint8_t *blk;
    size_t len, n;
    tapfile_reader_t r;

    n = tapfile_write_block(img, sizeof img, a, 3);
    n += tapfile_write_block(img + n, sizeof img - n, a, 1);
    CHECK(n == 8);
    tapfile_reader_init(&r, img, n);
    CHECK(tapfile_next(&r, &blk, &len) == 1 && len == 3 && blk[2] == 3);
    CHECK(tapfile_next(&r, &blk, &len) == 1 && len == 1 && blk[0] == 1);
    CHECK(tapfile_next(&r, &blk, &len) == 0);
    tapfile_reader_init(&r, img, 4);
    CHECK(tapfile_next(&r, &blk, &len) == -1);
}

/* Minimal reader for the test recording: 16-bit PCM, signal on channel 0. */
static void real_recording(const char *path)
{
    FILE *f = fopen(path, "rb");
    unsigned char h[44];
    long size;
    unsigned char *raw;
    int ch, rate, i, n, level = 0, have_edge = 0, blocks = 0;
    long last = 0;
    double mean = 0;
    uint8_t buf[256];
    tape_dec_t d;
    tape_dec_event_t ev;

    if (!f) {
        fprintf(stderr, "cannot open %s\n", path);
        failures++;
        return;
    }
    fseek(f, 0, SEEK_END);
    size = ftell(f);
    fseek(f, 0, SEEK_SET);
    raw = malloc(size);
    CHECK(fread(raw, 1, size, f) == (size_t)size);
    fclose(f);
    memcpy(h, raw, 44);
    ch = h[22] | h[23] << 8;
    rate = h[24] | h[25] << 8 | h[26] << 16 | h[27] << 24;

    /* Find the "data" chunk. */
    for (i = 12; i + 8 <= size; ) {
        long cs = raw[i + 4] | raw[i + 5] << 8 | raw[i + 6] << 16 | (long)raw[i + 7] << 24;
        if (memcmp(raw + i, "data", 4) == 0) {
            i += 8;
            break;
        }
        i += 8 + cs;
    }
    n = (int)((size - i) / (2 * ch));
    const unsigned char *s = raw + i;
#define SAMPLE(k) ((short)(s[(k) * 2 * ch] | s[(k) * 2 * ch + 1] << 8))
    for (int k = 0; k < n; k++)
        mean += SAMPLE(k);
    mean /= n;

    /* Edges with hysteresis around the mean, durations in T-states. */
    tape_dec_init(&d, buf, sizeof buf);
    for (int k = 0; k < n; k++) {
        double v = SAMPLE(k) - mean;
        int nl = v > 300 ? 1 : v < -300 ? -1 : level;
        if (nl != level && nl != 0) {
            if (have_edge) {
                ev = tape_dec_feed(&d, (uint32_t)((k - last) * (double)TAPE_CPU_HZ / rate));
                if (ev != TAPE_DEC_NONE) {
                    printf("  recording: block flag %02X, %u bytes, %s\n",
                           buf[0], (unsigned)d.len, ev == TAPE_DEC_BLOCK_OK ? "OK" : "BAD");
                    CHECK(ev == TAPE_DEC_BLOCK_OK);
                    blocks++;
                }
            }
            have_edge = 1;
            last = k;
            level = nl;
        }
    }
    ev = tape_dec_end(&d);
    if (ev != TAPE_DEC_NONE) {
        printf("  recording: block flag %02X, %u bytes, %s (at end)\n",
               buf[0], (unsigned)d.len, ev == TAPE_DEC_BLOCK_OK ? "OK" : "BAD");
        CHECK(ev == TAPE_DEC_BLOCK_OK);
        blocks++;
    }
    CHECK(blocks == 2);
    free(raw);
}

int main(int argc, char **argv)
{
    round_trip(0x00, 17, 0, 0);           /* header: long pilot */
    round_trip(0xFF, 255, 0, 0);
    round_trip(0x80, 1, 0, 0);
    round_trip(0x91, 200, 0.08, 0);       /* 8 % slow */
    round_trip(0x91, 200, -0.08, 0);      /* 8 % fast */
    round_trip(0xFF, 200, 0, 120);        /* +/-120 T (~34 us) edge jitter */
    unterminated_tail();
    tapfile();
    if (argc > 1)
        real_recording(argv[1]);
    if (failures == 0)
        printf("tape: OK\n");
    return failures ? 1 : 0;
}
