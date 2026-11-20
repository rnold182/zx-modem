/* netmgr.c - Wi-Fi station, saved networks, scan/join, and the NTP clock.
 *
 * Up to NET_SAVED_MAX networks are kept in flash, most recently used first.
 * A connector task keeps the station on one of them: whenever it isn't
 * connected it scans and tries the saved networks in range, strongest first,
 * then waits and tries again. A join from the Spectrum tries the new network
 * once and saves it on success; on failure the connector takes over again,
 * so a typo doesn't cost the working network.
 *
 * Every station operation (scan, connect) holds s_lock, so the connector, a
 * scan for the setup screen and a join never get in each other's way.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_netif_sntp.h"
#include "esp_wifi.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "sdkconfig.h"
#include "netmgr.h"

#define NVS_NS          "zxmodem"
#define TRY_TIMEOUT_MS  15000       /* one connection attempt */
#define RETRY_MS        10000       /* nothing in range: scan again after */

#define BIT_GOT_IP      BIT0
#define BIT_FAILED      BIT1

typedef struct {
    char ssid[33];
    char pass[65];
} saved_t;

static const char *TAG = "net";

static volatile net_state_t s_state = NET_NOT_SET_UP;
static esp_netif_ip_info_t s_ip;
static volatile bool s_clock_valid;
static char s_cur[33];                      /* network in use / being tried */
static saved_t s_saved[NET_SAVED_MAX];      /* most recent first */
static int s_saved_n;
static bool s_saved_in_ram_only;            /* the menuconfig network */
static volatile bool s_trying;              /* try_connect owns the events */
static volatile int s_reason;               /* last disconnect reason */
static volatile bool s_associated;          /* joined the AP (IP may follow) */
static EventGroupHandle_t s_events;
static SemaphoreHandle_t s_lock;
static TaskHandle_t s_connector;
static net_ap_t s_scan[NET_SCAN_MAX];
static int s_scan_count;

/* ---- Saved networks ----------------------------------------------------------- */

static int saved_find(const char *ssid)
{
    for (int i = 0; i < s_saved_n; i++)
        if (strcmp(s_saved[i].ssid, ssid) == 0)
            return i;
    return -1;
}

static void saved_store(void)
{
    nvs_handle_t h;

    s_saved_in_ram_only = false;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK)
        return;
    /* Written even when empty: "nothing saved" must not fall back to menuconfig. */
    nvs_set_blob(h, "nets", s_saved, s_saved_n * sizeof s_saved[0]);
    nvs_commit(h);
    nvs_close(h);
}

/* Put a network first in the list (new, or moved up), dropping the oldest. */
static void saved_add(const char *ssid, const char *pass)
{
    int i = saved_find(ssid);
    saved_t e = { 0 };

    strncpy(e.ssid, ssid, sizeof e.ssid - 1);
    strncpy(e.pass, pass, sizeof e.pass - 1);
    if (i < 0)
        i = s_saved_n < NET_SAVED_MAX ? s_saved_n++ : NET_SAVED_MAX - 1;
    memmove(&s_saved[1], &s_saved[0], i * sizeof s_saved[0]);
    s_saved[0] = e;
    saved_store();
}

static void saved_remove(int i)
{
    memmove(&s_saved[i], &s_saved[i + 1], (s_saved_n - i - 1) * sizeof s_saved[0]);
    s_saved_n--;
    memset(&s_saved[s_saved_n], 0, sizeof s_saved[0]);
    saved_store();
}

static void saved_load(void)
{
    nvs_handle_t h;
    size_t n = sizeof s_saved;
    char ssid[33], pass[65];

    if (nvs_open(NVS_NS, NVS_READWRITE, &h) == ESP_OK) {
        if (nvs_get_blob(h, "nets", s_saved, &n) == ESP_OK) {
            s_saved_n = n / sizeof s_saved[0];
            nvs_close(h);
            ESP_LOGI(TAG, "%d saved network(s)", s_saved_n);
            return;
        }
        /* Firmware 0.3 kept one network as "ssid"/"pass": move it over. */
        n = sizeof ssid;
        if (nvs_get_str(h, "ssid", ssid, &n) == ESP_OK) {
            n = sizeof pass;
            if (nvs_get_str(h, "pass", pass, &n) != ESP_OK)
                pass[0] = 0;
            nvs_erase_key(h, "ssid");
            nvs_erase_key(h, "pass");
            nvs_commit(h);
            nvs_close(h);
            if (ssid[0])
                saved_add(ssid, pass);
            else
                saved_store();
            ESP_LOGI(TAG, "moved the saved network to the new list");
            return;
        }
        nvs_close(h);
    }
    if (CONFIG_ZXMODEM_WIFI_SSID[0]) {
        strncpy(s_saved[0].ssid, CONFIG_ZXMODEM_WIFI_SSID, sizeof s_saved[0].ssid - 1);
        strncpy(s_saved[0].pass, CONFIG_ZXMODEM_WIFI_PASSWORD, sizeof s_saved[0].pass - 1);
        s_saved_n = 1;
        s_saved_in_ram_only = true;
        ESP_LOGI(TAG, "network from menuconfig: \"%s\"", s_saved[0].ssid);
    } else {
        ESP_LOGW(TAG, "no Wi-Fi network set: use Wi-Fi Setup on the Spectrum");
    }
}

/* ---- Events ------------------------------------------------------------------- */

static void on_sntp_sync(struct timeval *tv)
{
    (void)tv;
    s_clock_valid = true;
    ESP_LOGI(TAG, "clock set by NTP");
}

static void on_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        xTaskNotifyGive(s_connector);
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_CONNECTED) {
        s_associated = true;
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        wifi_event_sta_disconnected_t *d = data;
        if (s_state == NET_CONNECTED)
            ESP_LOGW(TAG, "Wi-Fi lost (reason %d)", d->reason);
        s_reason = d->reason;
        memset(&s_ip, 0, sizeof s_ip);
        if (s_trying) {
            xEventGroupSetBits(s_events, BIT_FAILED);
        } else {
            s_state = s_saved_n ? NET_CONNECTING : NET_NOT_SET_UP;
            xTaskNotifyGive(s_connector);
        }
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *e = data;
        s_ip = e->ip_info;
        s_state = NET_CONNECTED;
        ESP_LOGI(TAG, "connected to \"%s\", IP " IPSTR, s_cur, IP2STR(&s_ip.ip));
        xEventGroupSetBits(s_events, BIT_GOT_IP);
        esp_netif_sntp_start();             /* now NTP has a network to use */
    }
}

/* ---- Station operations (caller holds s_lock) --------------------------------- */

static void apply_config(const char *ssid, const char *pass)
{
    wifi_config_t wc = { 0 };

    strncpy((char *)wc.sta.ssid, ssid, sizeof wc.sta.ssid);
    strncpy((char *)wc.sta.password, pass, sizeof wc.sta.password);
    esp_wifi_set_config(WIFI_IF_STA, &wc);
}

/* Leave the current network without the connector reacting to it. */
static void disconnect_quietly(void)
{
    s_trying = true;
    esp_wifi_disconnect();
    vTaskDelay(pdMS_TO_TICKS(200));         /* let the disconnect event pass */
    s_trying = false;
}

/* One attempt. True once there is an IP address. */
static bool try_connect(const char *ssid, const char *pass)
{
    EventBits_t bits;

    ESP_LOGI(TAG, "trying \"%s\"", ssid);
    disconnect_quietly();
    strncpy(s_cur, ssid, sizeof s_cur - 1);
    s_cur[sizeof s_cur - 1] = 0;
    s_state = NET_CONNECTING;
    xEventGroupClearBits(s_events, BIT_GOT_IP | BIT_FAILED);
    s_associated = false;
    s_reason = 0;
    s_trying = true;
    apply_config(ssid, pass);
    esp_wifi_connect();
    bits = xEventGroupWaitBits(s_events, BIT_GOT_IP | BIT_FAILED, pdTRUE, pdFALSE,
                               pdMS_TO_TICKS(TRY_TIMEOUT_MS));
    if (!(bits & BIT_GOT_IP)) {
        esp_wifi_disconnect();
        vTaskDelay(pdMS_TO_TICKS(200));
    }
    s_trying = false;
    return bits & BIT_GOT_IP;
}

/* Raw scan into recs; returns the count or -1. */
static int scan_raw(wifi_ap_record_t *recs, uint16_t max)
{
    wifi_scan_config_t sc = { .show_hidden = false };
    uint16_t n = max;
    esp_err_t err = esp_wifi_scan_start(&sc, true);

    if (err == ESP_ERR_WIFI_STATE) {        /* station busy: stop it and retry */
        disconnect_quietly();
        err = esp_wifi_scan_start(&sc, true);
    }
    if (err == ESP_OK)
        err = esp_wifi_scan_get_ap_records(&n, recs);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "scan failed: %s", esp_err_to_name(err));
        return -1;
    }
    return n;
}

/* ---- Connector task ----------------------------------------------------------- */

static void connector_task(void *arg)
{
    static wifi_ap_record_t recs[40];

    (void)arg;
    for (;;) {
        /* Sleep until something changes; while disconnected, look again
         * every RETRY_MS. */
        bool idle = s_state == NET_CONNECTED || s_saved_n == 0;
        ulTaskNotifyTake(pdTRUE, idle ? portMAX_DELAY : pdMS_TO_TICKS(RETRY_MS));
        if (s_state == NET_CONNECTED || s_saved_n == 0)
            continue;

        xSemaphoreTake(s_lock, portMAX_DELAY);
        int n = scan_raw(recs, sizeof recs / sizeof recs[0]);
        bool tried[NET_SAVED_MAX] = { 0 };
        bool ok = false;
        while (n > 0 && !ok) {
            /* the strongest saved network in range not tried yet */
            int best = -1, best_rssi = -1000;
            for (int i = 0; i < n; i++) {
                int k = saved_find((const char *)recs[i].ssid);
                if (k >= 0 && !tried[k] && recs[i].rssi > best_rssi) {
                    best = k;
                    best_rssi = recs[i].rssi;
                }
            }
            if (best < 0)
                break;
            tried[best] = true;
            ok = try_connect(s_saved[best].ssid, s_saved[best].pass);
        }
        if (!ok) {
            s_state = s_saved_n ? NET_CONNECTING : NET_NOT_SET_UP;
            if (n >= 0)
                ESP_LOGI(TAG, "no saved network reachable, looking again in %d s",
                         RETRY_MS / 1000);
        }
        xSemaphoreGive(s_lock);
    }
}

/* ---- Public ------------------------------------------------------------------- */

esp_err_t netmgr_start(void)
{
    esp_err_t err = nvs_flash_init();       /* Wi-Fi keeps calibration data in NVS too */

    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    setenv("TZ", CONFIG_ZXMODEM_TZ, 1);
    tzset();
    saved_load();
    if (s_saved_n)
        s_state = NET_CONNECTING;

    s_events = xEventGroupCreate();
    s_lock = xSemaphoreCreateMutex();
    if (xTaskCreate(connector_task, "wifi_conn", 4096, NULL, 4, &s_connector) != pdPASS)
        return ESP_ERR_NO_MEM;

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&init));
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));   /* we keep our own list */
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, on_event, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, on_event, NULL));
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_start());      /* STA_START wakes the connector */

    /* SNTP is started on each new IP address (see on_event): started before
     * that, its first query fails and its retries back off for minutes. It
     * re-syncs every hour by itself. */
    esp_sntp_config_t sc = ESP_NETIF_SNTP_DEFAULT_CONFIG(CONFIG_ZXMODEM_NTP_SERVER);
    sc.start = false;
    sc.sync_cb = on_sntp_sync;
    return esp_netif_sntp_init(&sc);
}

void netmgr_status(net_status_t *st)
{
    wifi_ap_record_t ap;
    time_t now;

    memset(st, 0, sizeof *st);
    st->state = s_state;
    if (st->state != NET_NOT_SET_UP)
        strncpy(st->ssid, s_cur[0] ? s_cur : s_saved[0].ssid, sizeof st->ssid - 1);
    if (st->state == NET_CONNECTED) {
        memcpy(st->ip, &s_ip.ip.addr, 4);   /* lwIP keeps it first-octet-first */
        if (esp_wifi_sta_get_ap_info(&ap) == ESP_OK)
            st->rssi = ap.rssi;
    }
    time(&now);
    localtime_r(&now, &st->local);
    /* Before NTP the clock counts from 1970: any recent year means it's set. */
    st->clock_valid = s_clock_valid || st->local.tm_year + 1900 >= 2025;
}

static int by_rssi(const void *a, const void *b)
{
    return ((const net_ap_t *)b)->rssi - ((const net_ap_t *)a)->rssi;
}

static void mark_scan(void)
{
    for (int i = 0; i < s_scan_count; i++) {
        s_scan[i].saved = saved_find(s_scan[i].ssid) >= 0;
        s_scan[i].connected = s_state == NET_CONNECTED && strcmp(s_scan[i].ssid, s_cur) == 0;
    }
}

int netmgr_scan(const net_ap_t **list)
{
    static wifi_ap_record_t recs[40];
    int n;

    xSemaphoreTake(s_lock, portMAX_DELAY);
    n = scan_raw(recs, sizeof recs / sizeof recs[0]);
    xSemaphoreGive(s_lock);
    if (s_state != NET_CONNECTED)
        xTaskNotifyGive(s_connector);       /* the scan may have interrupted it */
    if (n < 0)
        return -1;

    /* One entry per name (the strongest access point), hidden ones left out. */
    s_scan_count = 0;
    for (int i = 0; i < n; i++) {
        const char *name = (const char *)recs[i].ssid;
        int j;
        if (!name[0])
            continue;
        for (j = 0; j < s_scan_count; j++)
            if (strcmp(s_scan[j].ssid, name) == 0)
                break;
        if (j < s_scan_count) {
            if (recs[i].rssi > s_scan[j].rssi)
                s_scan[j].rssi = recs[i].rssi;
            continue;
        }
        if (s_scan_count == NET_SCAN_MAX) {
            /* full: replace the weakest if this one is stronger */
            qsort(s_scan, s_scan_count, sizeof s_scan[0], by_rssi);
            if (recs[i].rssi <= s_scan[s_scan_count - 1].rssi)
                continue;
            j = s_scan_count - 1;
        } else {
            j = s_scan_count++;
        }
        memset(&s_scan[j], 0, sizeof s_scan[j]);
        strncpy(s_scan[j].ssid, name, sizeof s_scan[j].ssid - 1);
        s_scan[j].rssi = recs[i].rssi;
        s_scan[j].authmode = recs[i].authmode;
    }
    qsort(s_scan, s_scan_count, sizeof s_scan[0], by_rssi);
    mark_scan();
    ESP_LOGI(TAG, "scan: %d network(s)", s_scan_count);
    *list = s_scan;
    return s_scan_count;
}

int netmgr_last_scan(const net_ap_t **list)
{
    mark_scan();
    *list = s_scan;
    return s_scan_count;
}

static const char *reason_text(int reason, bool associated)
{
    switch (reason) {
    case WIFI_REASON_AUTH_EXPIRE:
    case WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT:
    case WIFI_REASON_AUTH_FAIL:
    case WIFI_REASON_HANDSHAKE_TIMEOUT:
        return "Wrong password";
    case WIFI_REASON_NO_AP_FOUND:
    case WIFI_REASON_NO_AP_FOUND_W_COMPATIBLE_SECURITY:
    case WIFI_REASON_NO_AP_FOUND_IN_AUTHMODE_THRESHOLD:
    case WIFI_REASON_NO_AP_FOUND_IN_RSSI_THRESHOLD:
        return "Network not found";
    default:
        return associated ? "No IP address" : "Could not connect";
    }
}

esp_err_t netmgr_join(const char *ssid, const char *password, char *msg, size_t msg_size)
{
    int k = saved_find(ssid);
    const char *pass = password;
    bool ok;

    if (!password[0] && k >= 0)
        pass = s_saved[k].pass;             /* a saved network: use its password */
    xSemaphoreTake(s_lock, portMAX_DELAY);
    ok = try_connect(ssid, pass);
    if (ok) {
        saved_add(ssid, pass);
        ESP_LOGI(TAG, "joined and saved \"%s\" (%d saved)", ssid, s_saved_n);
    } else {
        snprintf(msg, msg_size, "%s", reason_text(s_reason, s_associated));
        ESP_LOGW(TAG, "join failed: %s (reason %d)", msg, s_reason);
        s_state = s_saved_n ? NET_CONNECTING : NET_NOT_SET_UP;
    }
    xSemaphoreGive(s_lock);
    if (!ok)
        xTaskNotifyGive(s_connector);       /* back to the saved networks */
    return ok ? ESP_OK : ESP_FAIL;
}

esp_err_t netmgr_join_index(int index, const char *password, char *msg, size_t msg_size)
{
    if (index < 0 || index >= s_scan_count) {
        snprintf(msg, msg_size, "Scan again");
        return ESP_ERR_INVALID_ARG;
    }
    return netmgr_join(s_scan[index].ssid, password, msg, msg_size);
}

esp_err_t netmgr_forget_index(int index)
{
    int k;

    if (index < 0 || index >= s_scan_count || (k = saved_find(s_scan[index].ssid)) < 0)
        return ESP_ERR_NOT_FOUND;
    ESP_LOGW(TAG, "forgetting \"%s\"", s_saved[k].ssid);
    xSemaphoreTake(s_lock, portMAX_DELAY);
    bool in_use = strcmp(s_saved[k].ssid, s_cur) == 0;
    saved_remove(k);
    if (in_use) {                           /* leave it; the connector picks another */
        disconnect_quietly();
        s_cur[0] = 0;
        s_state = s_saved_n ? NET_CONNECTING : NET_NOT_SET_UP;
    }
    xSemaphoreGive(s_lock);
    xTaskNotifyGive(s_connector);
    return ESP_OK;
}

void netmgr_forget_all(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_saved_n = 0;
    memset(s_saved, 0, sizeof s_saved);
    saved_store();
    disconnect_quietly();
    s_cur[0] = 0;
    s_state = NET_NOT_SET_UP;
    xSemaphoreGive(s_lock);
    ESP_LOGW(TAG, "all saved networks forgotten");
}
