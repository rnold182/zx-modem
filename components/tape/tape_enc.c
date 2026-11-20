/* tape_enc.c - block -> pulse stream (pull iterator). */
#include <string.h>
#include "tape.h"

enum { PH_PILOT, PH_SYNC1, PH_SYNC2, PH_DATA, PH_PAUSE, PH_DONE };

void tape_enc_init(tape_enc_t *e, const tape_timing_t *tm,
                   const uint8_t *blk, size_t len)
{
    memset(e, 0, sizeof *e);
    e->tm = tm;
    e->blk = blk;
    e->len = len;
    e->phase = PH_PILOT;
    /* The flag byte picks the pilot length, exactly as SA-BYTES does. */
    e->count = (len > 0 && blk[0] < 0x80) ? tm->pilot_header : tm->pilot_data;
    e->bit = 0x80;
}

bool tape_enc_next(tape_enc_t *e, tape_pulse_t *out)
{
    out->pause = false;
    switch (e->phase) {
    case PH_PILOT:
        out->tstates = e->tm->pilot;
        if (--e->count == 0)
            e->phase = PH_SYNC1;
        return true;
    case PH_SYNC1:
        out->tstates = e->tm->sync1;
        e->phase = PH_SYNC2;
        return true;
    case PH_SYNC2:
        out->tstates = e->tm->sync2;
        e->phase = e->len ? PH_DATA : PH_PAUSE;
        return true;
    case PH_DATA:
        /* Two equal pulses per bit, MSB first. */
        out->tstates = (e->blk[e->pos] & e->bit) ? e->tm->one : e->tm->zero;
        if (e->half ^= 1)
            return true;
        e->bit >>= 1;
        if (e->bit == 0) {
            e->bit = 0x80;
            if (++e->pos == e->len)
                e->phase = PH_PAUSE;
        }
        return true;
    case PH_PAUSE:
        /* The edge that starts the pause ends the last data pulse. */
        out->tstates = (uint32_t)e->tm->pause_ms * (TAPE_CPU_HZ / 1000);
        out->pause = true;
        e->phase = PH_DONE;
        return true;
    default:
        return false;
    }
}
