/* fetch.c - HTTP/HTTPS GET for the modem's services.
 *
 * esp_http_client's open/read API doesn't follow redirects by itself, so we
 * do: on 301/302/303/307/308 it resolves the Location header into a new URL,
 * and we start a fresh request there (a new client, since the host or the
 * scheme may change). TLS uses the ESP-IDF certificate bundle.
 *
 * The content type comes from the response headers (an event callback,
 * since the client has no getter for response headers) and is checked
 * before the body is read, so a refused body is never downloaded.
 */
#include <ctype.h>
#include <stdio.h>
#include <string.h>
#include "esp_crt_bundle.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "fetch.h"

#define MAX_REDIRECTS 5
#define TIMEOUT_MS    30000
#define URL_MAX       512
#define BODY_MAX      (32 * 1024)   /* UTF-8 as fetched; shrinks to ASCII */

static const char *TAG = "fetch";

uint8_t *fetch_buffer(size_t *cap)
{
    static uint8_t buf[BODY_MAX];
    *cap = sizeof buf;
    return buf;
}

static bool is_redirect(int status)
{
    return status == 301 || status == 302 || status == 303 || status == 307 || status == 308;
}

/* "Text/8TML; charset=x" -> "text/8tml" */
static void set_ctype(char *dst, size_t size, const char *v)
{
    size_t n = 0;

    while (*v == ' ')
        v++;
    while (*v && *v != ';' && *v != ' ' && n < size - 1)
        dst[n++] = (char)tolower((unsigned char)*v++);
    dst[n] = 0;
}

static esp_err_t on_event(esp_http_client_event_t *evt)
{
    fetch_result_t *res = evt->user_data;

    if (evt->event_id == HTTP_EVENT_ON_HEADER && strcasecmp(evt->header_key, "Content-Type") == 0)
        set_ctype(res->ctype, sizeof res->ctype, evt->header_value);
    return ESP_OK;
}

bool fetch_type_refused(const char *type, const char *list)
{
    size_t tl = strlen(type);

    while (list && *list) {
        const char *e;
        size_t n;

        while (*list == ' ')
            list++;
        for (e = list; *e && *e != ' '; e++)
            ;
        n = (size_t)(e - list);
        if (n && list[n - 1] == '/') {
            if (tl >= n && strncasecmp(type, list, n) == 0)
                return true;
        } else if (n && tl == n && strncasecmp(type, list, n) == 0) {
            return true;
        }
        list = e;
    }
    return false;
}

static esp_err_t fail(fetch_result_t *res, fetch_err_t err, char *msg, size_t msg_size,
                      const char *text)
{
    res->err = err;
    snprintf(msg, msg_size, "%s", text);
    return ESP_FAIL;
}

esp_err_t fetch_get(const char *url, const fetch_opts_t *opts, uint8_t *buf, size_t cap,
                    fetch_result_t *res, char *msg, size_t msg_size)
{
    static char cur[URL_MAX];

    memset(res, 0, sizeof *res);
    res->url = cur;
    if (strlen(url) + 8 >= sizeof cur)
        return fail(res, FETCH_ERR_ADDRESS, msg, msg_size, "Bad address");
    if (strstr(url, "://"))
        snprintf(cur, sizeof cur, "%s", url);
    else
        snprintf(cur, sizeof cur, "http://%s", url);    /* a typed host/path */

    for (int hop = 0; hop <= MAX_REDIRECTS; hop++) {
        esp_http_client_config_t cfg = {
            .url = cur,
            .timeout_ms = TIMEOUT_MS,
            .crt_bundle_attach = esp_crt_bundle_attach,
            .disable_auto_redirect = true,
            .user_agent = "zxmodem (ZX Spectrum 48K)",
            .buffer_size = 2048,
            .event_handler = on_event,
            .user_data = res,
        };
        esp_http_client_handle_t c = esp_http_client_init(&cfg);
        esp_err_t err;

        if (!c)
            return fail(res, FETCH_ERR_ADDRESS, msg, msg_size, "Bad address");
        if (opts && opts->accept && *opts->accept)
            esp_http_client_set_header(c, "Accept", opts->accept);
        res->ctype[0] = 0;
        ESP_LOGI(TAG, "GET %s", cur);
        err = esp_http_client_open(c, 0);
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "open failed: %s", esp_err_to_name(err));
            esp_http_client_cleanup(c);
            return err == ESP_ERR_HTTP_EAGAIN
                ? fail(res, FETCH_ERR_TIMEOUT, msg, msg_size, "Timed out")
                : fail(res, FETCH_ERR_CONNECT, msg, msg_size, "Could not connect");
        }
        esp_http_client_fetch_headers(c);
        res->status = esp_http_client_get_status_code(c);

        if (is_redirect(res->status)) {
            if (hop == MAX_REDIRECTS) {
                esp_http_client_cleanup(c);
                return fail(res, FETCH_ERR_REDIRECTS, msg, msg_size, "Too many redirects");
            }
            /* Resolves Location against the current URL. */
            if (esp_http_client_set_redirection(c) == ESP_OK &&
                esp_http_client_get_url(c, cur, sizeof cur) == ESP_OK) {
                ESP_LOGI(TAG, "%d -> %s", res->status, cur);
                esp_http_client_cleanup(c);
                continue;
            }
            /* No usable Location: the redirect itself is the answer. */
        }

        if (opts && fetch_type_refused(res->ctype, opts->refuse)) {
            ESP_LOGI(TAG, "HTTP %d, type %s refused", res->status, res->ctype);
            esp_http_client_cleanup(c);
            return fail(res, FETCH_ERR_REFUSED, msg, msg_size, res->ctype);
        }

        /* Read the body (also for 4xx/5xx: the caller decides what to do). */
        while (res->len < cap) {
            int n = esp_http_client_read(c, (char *)buf + res->len, cap - res->len);
            if (n <= 0)
                break;
            res->len += n;
        }
        if (res->len == cap) {              /* full: is there more? */
            char probe;
            res->truncated = esp_http_client_read(c, &probe, 1) > 0;
        }
        ESP_LOGI(TAG, "HTTP %d, %s, %u bytes%s", res->status,
                 res->ctype[0] ? res->ctype : "no type", (unsigned)res->len,
                 res->truncated ? " (cut)" : "");
        esp_http_client_cleanup(c);
        return ESP_OK;
    }
    return fail(res, FETCH_ERR_REDIRECTS, msg, msg_size, "Too many redirects");
}
