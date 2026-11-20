/* translit.c - UTF-8 -> 7-bit ASCII (see translit.h). */
#include <string.h>
#include "translit.h"

/* U+00C0..U+017F -> base letter; '#' = more than one letter, see multi(). */
static const char latin[] =
    "AAAAAA#CEEEEIIII"      /* U+00C0 */
    "DNOOOOOxOUUUUY##"      /* U+00D0 */
    "aaaaaa#ceeeeiiii"      /* U+00E0 */
    "dnooooo/ouuuuy#y"      /* U+00F0 */
    "AaAaAaCcCcCcCcDd"      /* U+0100 */
    "DdEeEeEeEeEeGgGg"      /* U+0110 */
    "GgGgHhHhIiIiIiIi"      /* U+0120 */
    "Ii##JjKkkLlLlLlL"      /* U+0130 */
    "lLlNnNnNnnNnOoOo"      /* U+0140 */
    "Oo##RrRrRrSsSsSs"      /* U+0150 */
    "SsTtTtTtUuUuUuUu"      /* U+0160 */
    "UuUuWwYyYZzZzZzs";     /* U+0170 */

static const char *multi(uint32_t c)
{
    switch (c) {
    case 0x00C6: return "AE";
    case 0x00DE: return "TH";
    case 0x00DF: return "ss";
    case 0x00E6: return "ae";
    case 0x00FE: return "th";
    case 0x0132: return "IJ";
    case 0x0133: return "ij";
    case 0x0152: return "OE";
    case 0x0153: return "oe";
    default:     return "?";
    }
}

/* The ASCII for code point c ("" = drop it). At most n characters, n being
 * the length of its UTF-8 form (2 for U+0080..U+07FF, 3 up to U+FFFF). */
static const char *ascii_for(uint32_t c)
{
    if (c >= 0x00C0 && c <= 0x017F) {
        static char one[2];
        char ch = latin[c - 0x00C0];
        if (ch == '#')
            return multi(c);
        one[0] = ch;
        return one;
    }
    switch (c) {
    case 0x00A0: return " ";        /* no-break space */
    case 0x00B0: return " ";        /* degree sign: +7 C */
    case 0x00AB: case 0x00BB:       /* guillemets */
    case 0x201C: case 0x201D: case 0x201E: case 0x201F:
        return "\"";
    case 0x2018: case 0x2019: case 0x201A: case 0x201B: case 0x00B4:
        return "'";
    case 0x2010: case 0x2011: case 0x2012: case 0x2013: case 0x2014:
    case 0x2015: case 0x2212:
        return "-";
    case 0x2026: return "...";
    case 0x2022: case 0x00B7: return "*";
    case 0x20AC: return "EUR";
    case 0x2190: return "<-";
    case 0x2191: return "^";
    case 0x2192: return "->";
    case 0x2193: return "v";
    case 0x2009: case 0x200A: case 0x202F: case 0x2002: case 0x2003:
        return " ";                 /* thin and other spaces */
    case 0x200B: case 0x200C: case 0x200D: case 0xFE0E: case 0xFE0F: case 0xFEFF:
        return "";                  /* invisible: zero-width, emoji selectors, BOM */
    default:
        return "?";
    }
}

size_t translit_utf8(uint8_t *buf, size_t len)
{
    size_t in = 0, out = 0;

    while (in < len) {
        uint8_t b = buf[in];
        uint32_t c;
        size_t n, k;

        if (b < 0x80) {
            in++;
            if (b == '\r' || b == '\n' || b == '\t' || (b >= 32 && b < 127))
                buf[out++] = b;
            else if (b == 127)
                buf[out++] = '?';
            continue;                       /* other control bytes: dropped */
        }
        if ((b & 0xE0) == 0xC0) { n = 2; c = b & 0x1F; }
        else if ((b & 0xF0) == 0xE0) { n = 3; c = b & 0x0F; }
        else if ((b & 0xF8) == 0xF0) { n = 4; c = b & 0x07; }
        else { in++; buf[out++] = '?'; continue; }   /* stray continuation byte */

        for (k = 1; k < n; k++) {
            if (in + k >= len || (buf[in + k] & 0xC0) != 0x80)
                break;
            c = c << 6 | (buf[in + k] & 0x3F);
        }
        if (k < n) {                        /* cut short: one ? for the lead byte */
            in++;
            buf[out++] = '?';
            continue;
        }
        in += n;
        const char *a = n == 4 ? "?" : ascii_for(c);
        size_t al = strlen(a);
        memcpy(buf + out, a, al);           /* al <= n, and out + n <= in */
        out += al;
    }
    return out;
}
