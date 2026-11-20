/* tape_block.c - ROM timing table and block helpers. */
#include <string.h>
#include "tape.h"

const tape_timing_t tape_timing_rom = {
    .pilot        = 2168,
    .sync1        = 667,
    .sync2        = 735,
    .zero         = 855,
    .one          = 1710,
    .pilot_header = 8063,
    .pilot_data   = 3223,
    .pause_ms     = 1000,
};

uint8_t tape_checksum(const uint8_t *p, size_t n)
{
    uint8_t x = 0;
    while (n--)
        x ^= *p++;
    return x;
}

size_t tape_make_block(uint8_t flag, const uint8_t *payload, size_t n,
                       uint8_t *out, size_t out_size)
{
    if (out_size < n + 2)
        return 0;
    out[0] = flag;
    memcpy(out + 1, payload, n);
    out[n + 1] = tape_checksum(out, n + 1);
    return n + 2;
}
