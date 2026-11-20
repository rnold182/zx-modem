/* fetch.c - HTTP/HTTPS GET for the modem's services.
 *
 * esp_http_client's open/read API doesn't follow redirects by itself, so we
 * do: on 301/302/303/307/308 it resolves the Location header into a new URL,
 * and we start a fresh request there (a new client, since the host or the
 * scheme may change). TLS uses the ESP-IDF certificate bundle.
 */
#include <stdio.h>
#include <string.h>
#include "esp_crt_bundle.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "fetch.h"

#define MAX_REDIRECTS 5
#define TIMEOUT_MS    30000
#define URL_MAX       512

static const char *TAG = "fetch";

static bool is_redirect(int status)
{
    return status == 301 || status == 302 || status == 303 || status == 307 || status == 308;
}

esp_err_t fetch_get(const char *url, uint8_t *buf, size_t cap, fetch_result_t *res,
                    char *msg, size_t msg_size)
{
    static char cur[URL_MAX];
    esp_err_t err = ESP_FAIL;

    memset(res, 0, sizeof *res);
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
        };
        esp_http_client_handle_t c = esp_http_client_init(&cfg);
        if (!c) {
            snprintf(msg, msg_size, "Bad address");
            return ESP_ERR_INVALID_ARG;
        }
        esp_http_client_set_header(c, "Accept", "*/*");
        ESP_LOGI(TAG, "GET %s", cur);
        err = esp_http_client_open(c, 0);
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "open failed: %s", esp_err_to_name(err));
            snprintf(msg, msg_size, err == ESP_ERR_HTTP_EAGAIN ? "Timed out" : "Could not connect");
            esp_http_client_cleanup(c);
            return err;
        }
        esp_http_client_fetch_headers(c);
        res->status = esp_http_client_get_status_code(c);

        if (is_redirect(res->status) && hop < MAX_REDIRECTS) {
            /* Resolves Location against the current URL. */
            if (esp_http_client_set_redirection(c) == ESP_OK &&
                esp_http_client_get_url(c, cur, sizeof cur) == ESP_OK) {
                ESP_LOGI(TAG, "%d -> %s", res->status, cur);
                esp_http_client_cleanup(c);
                continue;
            }
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
        ESP_LOGI(TAG, "HTTP %d, %u bytes%s", res->status, (unsigned)res->len,
                 res->truncated ? " (cut)" : "");
        esp_http_client_cleanup(c);
        return ESP_OK;
    }
    snprintf(msg, msg_size, "Too many redirects");
    return ESP_FAIL;
}
