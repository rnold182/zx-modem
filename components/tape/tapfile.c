/* tapfile.c - .tap container in memory. */
#include <string.h>
#include "tape.h"

void tapfile_reader_init(tapfile_reader_t *r, const uint8_t *data, size_t size)
{
    r->data = data;
    r->size = size;
    r->pos = 0;
}

int tapfile_next(tapfile_reader_t *r, const uint8_t **blk, size_t *len)
{
    size_t n;

    if (r->pos == r->size)
        return 0;
    if (r->size - r->pos < 2)
        return -1;
    n = r->data[r->pos] | (size_t)r->data[r->pos + 1] << 8;
    if (r->size - r->pos - 2 < n)
        return -1;
    *blk = r->data + r->pos + 2;
    *len = n;
    r->pos += 2 + n;
    return 1;
}

size_t tapfile_write_block(uint8_t *out, size_t cap,
                           const uint8_t *blk, size_t len)
{
    if (len > 65535 || cap < len + 2)
        return 0;
    out[0] = (uint8_t)len;
    out[1] = (uint8_t)(len >> 8);
    memcpy(out + 2, blk, len);
    return len + 2;
}
