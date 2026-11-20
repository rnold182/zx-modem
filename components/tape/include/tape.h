/*
 * tape.h - portable ZX Spectrum tape signal library.
 *
 * Plain C99, no platform dependencies: shared by the ESP32 firmware and the
 * host tools. All durations are in Z80 T-states at 3.5 MHz, the unit the ROM
 * timings are defined in; each consumer converts at its own edge (WAV samples,
 * RMT ticks, timer microseconds).
 */
#ifndef TAPE_H
#define TAPE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TAPE_CPU_HZ 3500000u    /* 48K Z80 clock: 1 T-state ~ 0.2857 us */

/* ---- Timing ------------------------------------------------------------- */

typedef struct {
    uint16_t pilot;         /* T-states per pilot pulse */
    uint16_t sync1;         /* first sync pulse */
    uint16_t sync2;         /* second sync pulse */
    uint16_t zero;          /* each of the two pulses of a 0 bit */
    uint16_t one;           /* each of the two pulses of a 1 bit */
    uint16_t pilot_header;  /* pilot pulses when flag < 0x80 */
    uint16_t pilot_data;    /* pilot pulses when flag >= 0x80 */
    uint16_t pause_ms;      /* silence after the block */
} tape_timing_t;

/* Standard ROM SA-BYTES timing: 2168/667/735/855/1710, 8063/3223 pulses. */
extern const tape_timing_t tape_timing_rom;

/* ---- Blocks -------------------------------------------------------------
 * A block is the byte sequence on tape: flag, payload, checksum, where the
 * checksum is the XOR of all preceding bytes (so XOR over a whole valid
 * block is 0).
 */

/* XOR of n bytes. */
uint8_t tape_checksum(const uint8_t *p, size_t n);

/* Build flag + payload + checksum into out. Returns the block length
 * (n + 2), or 0 if out_size is too small. */
size_t tape_make_block(uint8_t flag, const uint8_t *payload, size_t n,
                       uint8_t *out, size_t out_size);

/* ---- Encoder: pull iterator ---------------------------------------------
 * Produces the pulse sequence for one block: pilot, sync1, sync2, two pulses
 * per bit (MSB first), then a pause. The output level toggles at the start of
 * every pulse, the pause included: that last edge ends the final data pulse
 * (a loader times each pulse between two edges), then the pause holds the
 * level.
 *
 * Pull model so the same state machine feeds both the WAV writer (a simple
 * loop) and the ESP32 RMT encoder (which asks for N symbols at a time).
 */

typedef struct {
    uint32_t tstates;   /* duration of this pulse */
    bool     pause;     /* true: the trailing silence (one edge, then hold) */
} tape_pulse_t;

typedef struct {
    const tape_timing_t *tm;
    const uint8_t *blk;
    size_t   len;
    size_t   pos;       /* current byte */
    uint32_t count;     /* pulses left in the current phase */
    uint8_t  phase;     /* pilot / sync / data / pause / done */
    uint8_t  bit;       /* current bit mask */
    uint8_t  half;      /* 0 or 1: which pulse of the bit */
} tape_enc_t;

void tape_enc_init(tape_enc_t *e, const tape_timing_t *tm,
                   const uint8_t *blk, size_t len);

/* Next pulse into *out. Returns false when the block (incl. pause) is done. */
bool tape_enc_next(tape_enc_t *e, tape_pulse_t *out);

/* ---- Decoder: push state machine ----------------------------------------
 * Fed with the duration between consecutive edges. Polarity-free: only
 * durations matter. Bits are classified by the sum of their two pulses.
 */

typedef enum {
    TAPE_DEC_NONE = 0,      /* nothing completed yet */
    TAPE_DEC_BLOCK_OK,      /* block in buffer, checksum valid */
    TAPE_DEC_BLOCK_BAD,     /* block in buffer, checksum or framing error */
    TAPE_DEC_OVERFLOW       /* block longer than the buffer (truncated) */
} tape_dec_event_t;

typedef struct {
    uint8_t *buf;
    size_t   cap;
    size_t   len;           /* bytes of the last/current block (<= cap) */
    uint32_t pilot_run;     /* consecutive pilot-length pulses seen */
    uint32_t prev;          /* first pulse of a pending bit pair */
    uint8_t  state;         /* hunt / pilot / sync / data */
    uint8_t  cur;           /* byte being assembled */
    uint8_t  nbits;         /* bits in cur */
} tape_dec_t;

void tape_dec_init(tape_dec_t *d, uint8_t *buf, size_t cap);

/* Feed one edge-to-edge duration. */
tape_dec_event_t tape_dec_feed(tape_dec_t *d, uint32_t tstates);

/* Signal end of input or a long gap: finishes any block in progress. */
tape_dec_event_t tape_dec_end(tape_dec_t *d);

/* ---- .tap container (in memory) -----------------------------------------
 * A .tap file is a sequence of [length:2 LE][block]. These work on memory
 * buffers so they stay portable; host tools do the file I/O.
 */

typedef struct {
    const uint8_t *data;
    size_t size;
    size_t pos;
} tapfile_reader_t;

void tapfile_reader_init(tapfile_reader_t *r, const uint8_t *data, size_t size);

/* Next block: 1 = blk and len set, 0 = end of data, -1 = malformed. */
int tapfile_next(tapfile_reader_t *r, const uint8_t **blk, size_t *len);

/* Append [len][blk] at out. Returns bytes written (len + 2), or 0 if it
 * doesn't fit or len > 65535. */
size_t tapfile_write_block(uint8_t *out, size_t cap,
                           const uint8_t *blk, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* TAPE_H */
