/*
 * translit.h - UTF-8 text to 7-bit ASCII, for the Spectrum.
 *
 * Plain C99, shared by the ESP32 firmware and the host tests.
 *   - curly quotes -> ' and ", dashes -> -, ... -> ..., NBSP -> space
 *   - accented Latin letters -> their base letter (incl. Hungarian
 *     a e i o o o u u u), ligatures -> two letters (ss, ae, oe)
 *   - emoji variation selectors, zero-width joiners and BOMs are dropped
 *   - CR, LF and TAB pass through; other control bytes are dropped
 *   - anything else (and broken UTF-8) -> ?
 * No replacement is longer than the bytes it replaces, so it works in place.
 */
#ifndef TRANSLIT_H
#define TRANSLIT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Convert buf[0..len) in place. Returns the new length (<= len). */
size_t translit_utf8(uint8_t *buf, size_t len);

#ifdef __cplusplus
}
#endif

#endif
