#ifndef TESTTAPE_H
#define TESTTAPE_H

#include <stddef.h>
#include <stdint.h>

/* Write the test tape as a .tap image into out. Returns its size, 0 if cap
 * is too small (256 bytes is plenty). */
size_t testtape_build(uint8_t *out, size_t cap);

/* First bytes of the 48K ROM, which the test program SAVEs back. */
extern const uint8_t testtape_rom_start[8];

#endif
