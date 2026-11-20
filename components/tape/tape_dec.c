/* tape_dec.c - pulse durations -> blocks (push state machine).
 *
 * Thresholds are wide on purpose (ROM values: pilot 2168, sync 667/735,
 * bit halves 855/1710 T): the Spectrum's own timing is within 0.3 %, but the
 * ESP32 timestamps edges from an ISR and the comparator adds a little jitter.
 * Bits are classified by the sum of their two halves (1710 vs 3420 T), which
 * cancels any asymmetry between rising and falling edges.
 */
#include <string.h>
#include "tape.h"

enum { ST_HUNT, ST_PILOT, ST_SYNC2, ST_DATA };

#define PILOT_MIN    1700u
#define PILOT_MAX    2700u
#define PILOT_NEEDED   64u      /* pilot pulses before a sync is believed */
#define SYNC_MIN      300u
#define SYNC_MAX     1100u
#define HALF_MIN      300u      /* shorter: a glitch, ends the block */
#define HALF_MAX     2600u      /* longer: the pause after the last bit */
#define BIT_SPLIT    2565u      /* pair sum: 1710 = 0, 3420 = 1 */

void tape_dec_init(tape_dec_t *d, uint8_t *buf, size_t cap)
{
    memset(d, 0, sizeof *d);
    d->buf = buf;
    d->cap = cap;
}

static void push_bit(tape_dec_t *d, int bit)
{
    d->cur = (uint8_t)(d->cur << 1 | bit);
    if (++d->nbits == 8) {
        if (d->len < d->cap)
            d->buf[d->len] = d->cur;
        d->len++;               /* keeps counting past cap: overflow */
        d->nbits = 0;
    }
}

/* End the block in progress and report it. */
static tape_dec_event_t finish(tape_dec_t *d)
{
    tape_dec_event_t ev = TAPE_DEC_NONE;

    /* A Spectrum often leaves the last half-pulse unterminated (no edge
     * follows it), so a pending first half decides the last bit alone. */
    if (d->state == ST_DATA && d->prev)
        push_bit(d, d->prev > BIT_SPLIT / 2);
    if (d->state == ST_DATA && d->len > 0) {
        if (d->len > d->cap) {
            d->len = d->cap;
            ev = TAPE_DEC_OVERFLOW;
        } else {
            ev = (d->len >= 2 && tape_checksum(d->buf, d->len) == 0)
                     ? TAPE_DEC_BLOCK_OK : TAPE_DEC_BLOCK_BAD;
        }
    }
    d->state = ST_HUNT;
    d->pilot_run = 0;
    d->prev = 0;
    return ev;
}

static void hunt(tape_dec_t *d, uint32_t t)
{
    if (t >= PILOT_MIN && t <= PILOT_MAX) {
        d->pilot_run++;
        d->state = ST_PILOT;
    } else if (d->state == ST_PILOT && d->pilot_run >= PILOT_NEEDED &&
               t >= SYNC_MIN && t <= SYNC_MAX) {
        d->state = ST_SYNC2;
    } else {
        d->pilot_run = 0;
        d->state = ST_HUNT;
    }
}

tape_dec_event_t tape_dec_feed(tape_dec_t *d, uint32_t t)
{
    tape_dec_event_t ev;

    switch (d->state) {
    case ST_SYNC2:
        if (t >= SYNC_MIN && t <= SYNC_MAX) {
            d->state = ST_DATA;
            d->len = 0;
            d->nbits = 0;
            d->cur = 0;
            d->prev = 0;
        } else {
            d->pilot_run = 0;
            d->state = ST_HUNT;
            hunt(d, t);
        }
        return TAPE_DEC_NONE;
    case ST_DATA:
        if (d->prev == 0) {
            if (t >= HALF_MIN && t <= HALF_MAX) {
                d->prev = t;
                return TAPE_DEC_NONE;
            }
        } else if (t >= HALF_MIN && t <= HALF_MAX) {
            push_bit(d, d->prev + t > BIT_SPLIT);
            d->prev = 0;
            return TAPE_DEC_NONE;
        }
        /* Out of range: the block is over. Let the pulse start a new hunt. */
        ev = finish(d);
        hunt(d, t);
        return ev;
    default:
        hunt(d, t);
        return TAPE_DEC_NONE;
    }
}

tape_dec_event_t tape_dec_end(tape_dec_t *d)
{
    return finish(d);
}
