/* svc_http.c - the http service, 0x01 (docs/link-protocol.md 6.4).
 *
 * A web client for programs with their own rules: the client sends an
 * absolute address, the Accept header and the content types it refuses; the
 * modem fetches, follows redirects and filters by type before reading the
 * body. It never resolves relative links or looks inside the body: those
 * are the client's job (zx-vvv does them on the Spectrum).
 *
 * G: [flags][max lo][max hi][url] 0 [accept] 0 [refuse]
 *    -> url-info (type 3: final url, 0, content type), then body (type 0);
 *       or error [code][message].
 *    flags bit 1: one reply instead: body (type 0) whose data is
 *       [final url] 0 [content type] 0 [body], all within max. Every reply
 *       costs two tape blocks of ~2 s pilot each, so this saves two.
 */
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include "esp_log.h"
#include "fetch.h"
#include "netmgr.h"
#include "translit.h"
#include "link.h"

enum { HTTP_FLAG_ASCII = 0x01, HTTP_FLAG_ONE = 0x02 };
enum { ERR_NO_WIFI = 1, ERR_BAD_REQUEST = 7 };

static const char *TAG = "http";

/* Copies the 0-terminated field at *p (up to end) into dst; false if it
 * doesn't fit. A missing terminator at the end of the request is fine. */
static bool take_field(const uint8_t **p, const uint8_t *end, char *dst, size_t size)
{
    size_t n = 0;

    while (*p < end && **p) {
        if (n == size - 1)
            return false;
        dst[n++] = (char)*(*p)++;
    }
    dst[n] = 0;
    if (*p < end)
        (*p)++;                             /* the 0 */
    return true;
}

static bool is_absolute(const char *url)
{
    return strncasecmp(url, "http://", 7) == 0 || strncasecmp(url, "https://", 8) == 0;
}

static void http_get(const uint8_t *a, size_t n)
{
    char url[300], accept[80], refuse[120], msg[64];
    const uint8_t *p = a + 3, *end = a + n;
    uint8_t info[300 + 1 + sizeof ((fetch_result_t *)0)->ctype];
    fetch_result_t res;
    fetch_opts_t opts = { .accept = accept, .refuse = refuse };
    net_status_t st;
    size_t max, len, cap, ul, tl;
    uint8_t flags, *body = fetch_buffer(&cap);

    if (n < 4 || !take_field(&p, end, url, sizeof url) ||
        !take_field(&p, end, accept, sizeof accept) ||
        !take_field(&p, end, refuse, sizeof refuse)) {
        link_send_error_code(ERR_BAD_REQUEST, "Bad request");
        return;
    }
    flags = a[0];
    max = a[1] | a[2] << 8;
    if (!is_absolute(url)) {
        link_send_error_code(FETCH_ERR_ADDRESS, "Bad address");
        return;
    }
    netmgr_status(&st);
    if (st.state != NET_CONNECTED) {
        link_send_error_code(ERR_NO_WIFI, "No Wi-Fi");
        return;
    }
    ESP_LOGI(TAG, "G %s (accept '%s', refuse '%s', max %u)", url, accept, refuse, (unsigned)max);
    if (fetch_get(url, &opts, body, cap, &res, msg, sizeof msg) != ESP_OK) {
        /* a refused type keeps the server's status: a 404 sent as an HTML
         * page is a 404 to the reader, not a type problem */
        link_send_error_http((uint8_t)res.err, msg,
                             res.err == FETCH_ERR_REFUSED ? (uint16_t)res.status : 0);
        return;
    }

    /* url-info: the final address and the type, then the body. */
    ul = strlen(res.url);
    if (ul > 300)
        ul = 300;
    tl = strlen(res.ctype);
    for (size_t i = 0; i < ul; i++)
        info[i] = res.url[i] > 32 && res.url[i] < 127 ? res.url[i] : '?';
    info[ul] = 0;
    memcpy(info + ul + 1, res.ctype, tl);
    len = flags & HTTP_FLAG_ASCII ? translit_utf8(body, res.len) : res.len;

    if (flags & HTTP_FLAG_ONE) {
        /* [url] 0 [type] 0 then the body, moved up in the same buffer */
        size_t pre = ul + 1 + tl + 1, room = max > pre ? max - pre : 0;

        if (room > cap - pre)
            room = cap - pre;
        if (len > room) {
            len = room;
            res.truncated = true;
        }
        memmove(body + pre, body, len);
        memcpy(body, info, ul + 1 + tl);
        body[pre - 1] = 0;
        len += pre;
        link_send_ex(RESP_BODY, body, len, (uint16_t)res.status,
                     len > 0xFFFF ? 0xFFFF : (uint16_t)len, res.truncated ? LINK_TRUNCATED : 0);
        return;
    }

    link_send(RESP_URLINFO, info, ul + 1 + tl, (uint16_t)res.status);
    if (len > max) {
        len = max;
        res.truncated = true;
    }
    link_send_ex(RESP_BODY, body, len, (uint16_t)res.status,
                 len > 0xFFFF ? 0xFFFF : (uint16_t)len, res.truncated ? LINK_TRUNCATED : 0);
}

void svc_http(uint8_t cmd, const uint8_t *args, size_t nargs)
{
    if (cmd == 'G')
        http_get(args, nargs);
    else
        link_send_error("Unknown request");
}
