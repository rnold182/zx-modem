#ifndef VVV_URL_H
#define VVV_URL_H

#include <stddef.h>

#define VVV_URL_MAX 255     /* the longest address zx-vvv sends (8TML spec 5.4) */

enum {
    VVV_URL_OK = 0,         /* out = the absolute address to fetch */
    VVV_URL_SAME = 1,       /* fragment only or empty: the current page */
    VVV_URL_NOFOLLOW = 2,   /* not http or https: shown, can't be followed */
    VVV_URL_LONG = 3,       /* longer than VVV_URL_MAX */
};

/* Resolve the link ref against the page address base (NULL or "" = ref
 * was typed by the reader) into out, size bytes (at least 2 * VVV_URL_MAX). */
int vvv_url(const char *base, const char *ref, char *out, size_t size);

#endif
