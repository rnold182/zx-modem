/* link.c - request/response link over the tape signal (docs/link-protocol.md).
 *
 * Requests arrive from the RX task through a queue; this task decodes them,
 * dispatches on [service][command] and sends the response as header + data
 * block pairs. Tapes for the PLAY button go through the same queue, so the
 * transmitter only ever has one user.
 */
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "tape.h"
#include "tapeio.h"
#include "apps.h"
#include "fetch.h"
#include "netmgr.h"
#include "translit.h"
#include "link.h"

#define REQ_MAX       302           /* flag + 300 payload + checksum */
#define CHUNK_MAX    1024
#define ECHO_GUARD_MS 300           /* receiver stays off a little after TX */

enum { SVC_SYSTEM = 0x00, SVC_BASIC = 0x03 };
enum { RESP_BODY = 0, RESP_ERROR = 1, RESP_NETLIST = 4, RESP_WIFI = 5, RESP_OVERLAY = 6, RESP_INFO = 7 };
enum { HDR_FLAG = 0x90, DATA_FLAG = 0x91, FINAL = 0x01, TRUNCATED = 0x02 };

#define FETCH_RAW_MAX (32 * 1024)          /* UTF-8 as fetched; shrinks to ASCII */

typedef struct {
    bool is_tape;
    uint16_t len;
    union {
        uint8_t req[REQ_MAX];
        struct {
            const uint8_t *data;
            const char *name;
        } tape;
    };
} job_t;

/* Responses: ROM timing, 200 ms after each block for the Spectrum to react.
 * The pilot can't be much shorter: after the first edge LD-BYTES waits almost
 * 1 s on purpose, then wants 256 pairs of pilot pulses, so anything under
 * ~2200 pulses is over before it is heard. A shorter pilot needs our own
 * loader (M6). */
static const tape_timing_t s_reply_timing = {
    .pilot = 2168, .sync1 = 667, .sync2 = 735, .zero = 855, .one = 1710,
    .pilot_header = 3223, .pilot_data = 3223, .pause_ms = 200,
};

static const char *TAG = "link";
static QueueHandle_t s_jobs;
static volatile bool s_sending;

static void send_block(uint8_t flag, const uint8_t *p, size_t n)
{
    static uint8_t blk[CHUNK_MAX + 2];
    size_t len = tape_make_block(flag, p, n, blk, sizeof blk);
    ESP_ERROR_CHECK(tapeio_tx_block(blk, len, &s_reply_timing));
}

/* field45 goes into header bytes 4-5: the total length, or for an overlay
 * its load address. flags are ORed into every header (TRUNCATED). */
static void send_response_ex(uint8_t type, const uint8_t *data, size_t len,
                             uint16_t http, uint16_t field45, uint8_t flags)
{
    size_t off = 0;
    uint8_t idx = 0;

    do {
        size_t n = len - off > CHUNK_MAX ? CHUNK_MAX : len - off;
        size_t total = field45;
        uint8_t hdr[10] = {
            type, (uint8_t)((off + n == len ? FINAL : 0) | flags),
            (uint8_t)n, (uint8_t)(n >> 8),
            (uint8_t)total, (uint8_t)(total >> 8),
            idx, PROTO_VERSION,
            (uint8_t)http, (uint8_t)(http >> 8),
        };
        send_block(HDR_FLAG, hdr, sizeof hdr);
        if (n)
            send_block(DATA_FLAG, data + off, n);
        off += n;
        idx++;
    } while (off < len);
}

static void send_response(uint8_t type, const uint8_t *data, size_t len, uint16_t http)
{
    send_response_ex(type, data, len, http, len > 0xFFFF ? 0xFFFF : (uint16_t)len, 0);
}

static void send_error(const char *msg)
{
    ESP_LOGW(TAG, "error reply: %s", msg);
    send_response(RESP_ERROR, (const uint8_t *)msg, strlen(msg), 0);
}

/* V: modem status, then the app list for the menu:
 * [count] and per app [id][kind][flags (bit 0 available)][len][name]. */
static void reply_info(void)
{
    net_status_t st;
    uint8_t d[19 + 32 + 1 + 8 * (4 + 24)];
    size_t n, len, count;
    const app_t *apps = apps_list(&count);

    netmgr_status(&st);
    d[0] = FW_VERSION_MAJOR;
    d[1] = FW_VERSION_MINOR;
    d[2] = PROTO_VERSION;
    d[3] = (uint8_t)st.state;
    memcpy(d + 4, st.ip, 4);
    d[8] = (uint8_t)st.rssi;
    d[9] = st.clock_valid;
    d[10] = (uint8_t)(st.local.tm_year + 1900);
    d[11] = (uint8_t)((st.local.tm_year + 1900) >> 8);
    d[12] = (uint8_t)(st.local.tm_mon + 1);
    d[13] = (uint8_t)st.local.tm_mday;
    d[14] = (uint8_t)st.local.tm_hour;
    d[15] = (uint8_t)st.local.tm_min;
    d[16] = (uint8_t)st.local.tm_sec;
    d[17] = (uint8_t)st.local.tm_wday;
    n = strlen(st.ssid);
    d[18] = (uint8_t)n;
    for (size_t i = 0; i < n; i++)          /* the Spectrum only shows ASCII */
        d[19 + i] = st.ssid[i] >= 32 && st.ssid[i] < 127 ? st.ssid[i] : '?';
    len = 19 + n;
    if (count > 8)
        count = 8;
    d[len++] = (uint8_t)count;
    for (size_t i = 0; i < count; i++) {
        size_t nl = strlen(apps[i].name);
        if (nl > 24)
            nl = 24;
        d[len++] = apps[i].id;
        d[len++] = apps[i].kind;
        d[len++] = apps[i].code ? 1 : 0;
        d[len++] = (uint8_t)nl;
        memcpy(d + len, apps[i].name, nl);
        len += nl;
    }
    ESP_LOGI(TAG, "info: Wi-Fi %d, clock %s, %02d:%02d:%02d, %u app(s)", st.state,
             st.clock_valid ? "set" : "not set", st.local.tm_hour, st.local.tm_min,
             st.local.tm_sec, (unsigned)count);
    send_response(RESP_INFO, d, len, 0);
}

/* L: scan (rescan = false: the last scan again, with fresh marks).
 * Records [rssi][authmode][flags][len][name], strongest first; flags bit 0
 * saved, bit 1 connected. Names are shown as ASCII; the real ones stay here
 * for J and F. */
static void reply_netlist(bool rescan)
{
    static uint8_t d[NET_SCAN_MAX * 36];
    const net_ap_t *list;
    int n = rescan ? netmgr_scan(&list) : netmgr_last_scan(&list);
    size_t len = 0;

    if (n < 0) {
        send_error("Scan failed");
        return;
    }
    for (int i = 0; i < n; i++) {
        size_t sl = strlen(list[i].ssid);
        d[len++] = (uint8_t)list[i].rssi;
        d[len++] = list[i].authmode;
        d[len++] = (list[i].saved ? 1 : 0) | (list[i].connected ? 2 : 0);
        d[len++] = (uint8_t)sl;
        for (size_t k = 0; k < sl; k++)
            d[len++] = list[i].ssid[k] >= 32 && list[i].ssid[k] < 127 ? list[i].ssid[k] : '?';
    }
    send_response(RESP_NETLIST, d, len, 0);
}

/* J: [index][password...] joins scan entry index; [0xFF][name][0][password...]
 * joins a network by name (a hidden one). An empty password for a saved
 * network means its saved one. */
static void reply_join(const uint8_t *a, size_t n)
{
    char ssid[33] = "", pass[65] = "", msg[40];
    net_status_t st;
    size_t i = 1, k = 0;
    esp_err_t err;

    if (n < 1) {
        send_error("Bad request");
        return;
    }
    if (a[0] == 0xFF) {
        while (i < n && a[i] && k < sizeof ssid - 1)
            ssid[k++] = (char)a[i++];
        i++;                                /* the 0 after the name */
    }
    for (k = 0; i < n && k < sizeof pass - 1; )
        pass[k++] = (char)a[i++];
    err = a[0] == 0xFF ? netmgr_join(ssid, pass, msg, sizeof msg)
                       : netmgr_join_index(a[0], pass, msg, sizeof msg);
    memset(pass, 0, sizeof pass);
    if (err != ESP_OK) {
        send_error(msg);
        return;
    }
    netmgr_status(&st);
    send_response(RESP_WIFI, st.ip, 4, 0);
}

/* F: [index] forgets scan entry index's saved network; replies with the
 * list again (not rescanned), so the marks update. */
static void reply_forget(const uint8_t *a, size_t n)
{
    if (n < 1 || netmgr_forget_index(a[0]) != ESP_OK) {
        send_error("Not saved");
        return;
    }
    reply_netlist(false);
}

/* O: [id] -> that app's code (type 6), header bytes 4-5 = load address. */
static void reply_overlay(const uint8_t *a, size_t n)
{
    const app_t *app = n < 1 ? NULL : apps_find(a[0]);

    if (!app) {
        send_error("No such app");
        return;
    }
    if (!app->code) {
        send_error("Coming soon");
        return;
    }
    ESP_LOGI(TAG, "app %u: %s, %u bytes", app->id, app->name,
             (unsigned)(app->code_end - app->code));
    send_response_ex(RESP_OVERLAY, app->code, app->code_end - app->code, 0, app->addr, 0);
}

/* basic F: [max lo][max hi][url...] -> body (type 0) as ASCII, at most max
 * bytes, with the HTTP status; error only when there is no answer at all. */
static void reply_basic_fetch(const uint8_t *a, size_t n)
{
    static uint8_t body[FETCH_RAW_MAX];
    char url[300], msg[40];
    fetch_result_t res;
    net_status_t st;
    size_t max, len;

    if (n < 3) {
        send_error("No address");
        return;
    }
    max = a[0] | a[1] << 8;
    len = n - 2 < sizeof url - 1 ? n - 2 : sizeof url - 1;
    memcpy(url, a + 2, len);
    url[len] = 0;
    netmgr_status(&st);
    if (st.state != NET_CONNECTED) {
        send_error("No Wi-Fi");
        return;
    }
    if (fetch_get(url, body, sizeof body, &res, msg, sizeof msg) != ESP_OK) {
        send_error(msg);
        return;
    }
    len = translit_utf8(body, res.len);
    if (len > max) {
        len = max;
        res.truncated = true;
    }
    send_response_ex(RESP_BODY, body, len, (uint16_t)res.status,
                     len > 0xFFFF ? 0xFFFF : (uint16_t)len, res.truncated ? TRUNCATED : 0);
}

static void handle_request(const uint8_t *blk, size_t len)
{
    /* blk = flag, payload, checksum; payload = service, command, arguments */
    if (len < 4) {
        send_error("Bad request");
        return;
    }
    uint8_t svc = blk[1], cmd = blk[2];
    const uint8_t *args = blk + 3;
    size_t nargs = len - 4;

    ESP_LOGI(TAG, "request: service %u, command '%c', %u byte(s) of arguments",
             svc, cmd >= 32 && cmd < 127 ? cmd : '?', (unsigned)nargs);
    if (svc == SVC_BASIC && cmd == 'F')
        reply_basic_fetch(args, nargs);
    else if (svc != SVC_SYSTEM)
        send_error("Unknown request");
    else if (cmd == 'V')
        reply_info();
    else if (cmd == 'L')
        reply_netlist(true);
    else if (cmd == 'F')
        reply_forget(args, nargs);
    else if (cmd == 'J')
        reply_join(args, nargs);
    else if (cmd == 'O')
        reply_overlay(args, nargs);
    else
        send_error("Unknown request");
}

static void play_tape(const uint8_t *tap, size_t n, const char *name)
{
    tapfile_reader_t r;
    const uint8_t *blk;
    size_t len;

    ESP_LOGI(TAG, "PLAY: %s", name);
    tapfile_reader_init(&r, tap, n);
    while (tapfile_next(&r, &blk, &len) == 1) {
        ESP_LOGI(TAG, "TX block: flag %02X, %u bytes", blk[0], (unsigned)len);
        ESP_ERROR_CHECK(tapeio_tx_block(blk, len, &tape_timing_rom));
    }
    ESP_LOGI(TAG, "PLAY: done");
}

static void link_task(void *arg)
{
    static job_t job;

    (void)arg;
    for (;;) {
        xQueueReceive(s_jobs, &job, portMAX_DELAY);
        s_sending = true;
        tapeio_rx_enable(false);
        if (job.is_tape)
            play_tape(job.tape.data, job.len, job.tape.name);
        else
            handle_request(job.req, job.len);
        vTaskDelay(pdMS_TO_TICKS(ECHO_GUARD_MS));
        xQueueReset(s_jobs);                /* drop anything heard meanwhile */
        tapeio_rx_enable(true);
        s_sending = false;
    }
}

esp_err_t link_start(void)
{
    s_jobs = xQueueCreate(2, sizeof(job_t));
    if (!s_jobs || xTaskCreate(link_task, "link", 10240, NULL, 6, NULL) != pdPASS)
        return ESP_ERR_NO_MEM;
    return ESP_OK;
}

void link_post_request(const uint8_t *blk, size_t len)
{
    static job_t job;                       /* only the RX task calls this */

    if (len > REQ_MAX) {
        ESP_LOGW(TAG, "request too long (%u bytes), ignored", (unsigned)len);
        return;
    }
    job.is_tape = false;
    job.len = (uint16_t)len;
    memcpy(job.req, blk, len);
    if (xQueueSend(s_jobs, &job, 0) != pdTRUE)
        ESP_LOGW(TAG, "busy, request dropped");
}

void link_post_tape(const uint8_t *tap, size_t len, const char *name)
{
    job_t job = { .is_tape = true, .len = (uint16_t)len };

    job.tape.data = tap;
    job.tape.name = name;
    if (s_sending || xQueueSend(s_jobs, &job, 0) != pdTRUE)
        ESP_LOGW(TAG, "busy, PLAY ignored");
}

bool link_sending(void)
{
    return s_sending;
}
