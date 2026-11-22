/* url.c - zx-vvv's address rules, the C reference for zx/url.asm.
 *
 * The Spectrum resolves every link itself (8TML spec 9.1) and sends the
 * modem only absolute addresses. This file is the readable model of the Z80
 * code: the same steps in the same order, tested on the host against
 * url_cases.txt, the same table the Spectrum's self-test runs.
 *
 * Rules, in order:
 *   1. A typed address (no base): no "://" means "http://" in front.
 *   2. Drop "#fragment". Nothing left = the current page (VVV_URL_SAME).
 *   3. RFC 3986 5.2.2 against the base: a scheme = absolute; "//" =
 *      network path; "/" = absolute path; "?" = new query; anything else is
 *      merged with the base's directory. 5.2.4 then removes "." and ".."
 *      segments from the path (never above the root); the query is left
 *      alone.
 *   4. Only http and https can be followed (VVV_URL_NOFOLLOW).
 *   5. An empty path or one ending in "/" gets "index.8tml".
 */
#include <ctype.h>
#include <string.h>
#include "url.h"

static int prefix_nocase(const char *s, const char *p)
{
    for (; *p; s++, p++)
        if (tolower((unsigned char)*s) != *p)
            return 0;
    return 1;
}

/* Length of the scheme at s including its ':', or 0 if s has none:
 * a letter, then letters, digits, '+', '-', '.', then ':'. */
static size_t scheme_len(const char *s)
{
    size_t i = 0;

    if (!isalpha((unsigned char)s[0]))
        return 0;
    while (isalnum((unsigned char)s[i]) || s[i] == '+' || s[i] == '-' || s[i] == '.')
        i++;
    return s[i] == ':' ? i + 1 : 0;
}

/* End of the authority: after "scheme://", up to '/', '?' or the end. */
static size_t authority_end(const char *s)
{
    size_t i = scheme_len(s);

    if (s[i] != '/' || s[i + 1] != '/')
        return i;
    for (i += 2; s[i] && s[i] != '/' && s[i] != '?'; i++)
        ;
    return i;
}

/* RFC 3986 5.2.4 on the path at p (it starts with '/', ends at '?' or the
 * end), in place; the query moves down after it. */
static void remove_dots(char *p)
{
    char *r = p, *w = p;
    int trailing = 0;

    while (*r == '/') {
        char *seg = r + 1, *e = seg;
        size_t n;

        while (*e && *e != '/' && *e != '?')
            e++;
        n = (size_t)(e - seg);
        if (n == 1 && seg[0] == '.') {
            trailing = 1;
        } else if (n == 2 && seg[0] == '.' && seg[1] == '.') {
            while (w > p && *--w != '/')    /* back to the previous '/' */
                ;
            trailing = 1;
        } else {
            *w++ = '/';
            memmove(w, seg, n);
            w += n;
            trailing = 0;
        }
        r = e;
    }
    if (trailing || w == p)
        *w++ = '/';
    memmove(w, r, strlen(r) + 1);           /* the query, if any */
}

int vvv_url(const char *base, const char *ref, char *out, size_t size)
{
    char tmp[VVV_URL_MAX * 2 + 16];
    size_t rl, a, sl;
    const char *q;

    /* 1. typed address */
    if (!base || !*base) {
        if (strstr(ref, "://")) {
            if (strlen(ref) >= sizeof tmp)
                return VVV_URL_LONG;
            strcpy(tmp, ref);
        } else {
            if (strlen(ref) + 7 >= sizeof tmp)
                return VVV_URL_LONG;
            strcpy(tmp, "http://");
            strcat(tmp, ref);
        }
        ref = tmp;
        base = tmp;
    }

    /* 2. the fragment */
    for (rl = 0; ref[rl] && ref[rl] != '#'; rl++)
        ;
    if (rl == 0)
        return VVV_URL_SAME;

    /* 3. resolve into out */
    sl = scheme_len(ref);
    if (rl + 1 > size)
        return VVV_URL_LONG;
    if (sl) {                                       /* absolute */
        memcpy(out, ref, rl);
        out[rl] = 0;
    } else if (ref[0] == '/' && ref[1] == '/') {    /* network path */
        sl = scheme_len(base);
        if (sl + rl + 1 > size)
            return VVV_URL_LONG;
        memcpy(out, base, sl);
        memcpy(out + sl, ref, rl);
        out[sl + rl] = 0;
    } else {
        a = authority_end(base);
        if (ref[0] == '/') {                        /* absolute path */
            if (a + rl + 1 > size)
                return VVV_URL_LONG;
            memcpy(out, base, a);
        } else if (ref[0] == '?') {                 /* new query */
            for (q = base + a; *q && *q != '?' && *q != '#'; q++)
                ;
            a = (size_t)(q - base);
            if (a + rl + 1 > size)
                return VVV_URL_LONG;
            memcpy(out, base, a);
        } else {                                    /* merge with the directory */
            size_t d = a;
            for (q = base + a; *q && *q != '?' && *q != '#'; q++)
                if (*q == '/')
                    d = (size_t)(q - base) + 1;
            if (d == a) {                           /* no path: the root */
                if (a + 1 + rl + 1 > size)
                    return VVV_URL_LONG;
                memcpy(out, base, a);
                out[a] = '/';
                a++;
            } else {
                if (d + rl + 1 > size)
                    return VVV_URL_LONG;
                memcpy(out, base, d);
                a = d;
            }
        }
        memcpy(out + a, ref, rl);
        out[a + rl] = 0;
    }
    a = authority_end(out);
    if (out[a] != '/') {                            /* "http://h" or "http://h?q" */
        if (strlen(out) + 2 > size)
            return VVV_URL_LONG;
        memmove(out + a + 1, out + a, strlen(out + a) + 1);
        out[a] = '/';
    }
    remove_dots(out + a);

    /* 4. followable? */
    sl = scheme_len(out);
    if (!((sl == 5 && prefix_nocase(out, "http:")) ||
          (sl == 6 && prefix_nocase(out, "https:"))) ||
        out[sl] != '/' || out[sl + 1] != '/')
        return VVV_URL_NOFOLLOW;

    /* 5. index.8tml */
    for (q = out + a; *q && *q != '?'; q++)
        ;
    if (q[-1] == '/') {
        size_t at = (size_t)(q - out), len = strlen(out);
        if (len + 10 + 1 > size)
            return VVV_URL_LONG;
        memmove(out + at + 10, out + at, len - at + 1);
        memcpy(out + at, "index.8tml", 10);
    }
    return strlen(out) > VVV_URL_MAX ? VVV_URL_LONG : VVV_URL_OK;
}
