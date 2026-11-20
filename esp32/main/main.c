/*
 * zxmodem firmware - M2: link layer, system service, menu bootstrap.
 *
 * PLAY (short press): plays the ZX MODEM menu into EAR (type LOAD "" first).
 * PLAY (hold 2-5 s):  plays the tape test program instead (see testtape.c).
 * PLAY (hold 5 s+):   forgets all saved Wi-Fi networks.
 * Requests from the Spectrum (flag 0x80) are answered by link.c; any other
 * block it SAVEs is decoded and logged.
 *
 * LED: blue = sending, yellow = receiving, then green (good block) or red
 * (bad) for 2 s. Idle: a short blink every 2 s, green when Wi-Fi is up,
 * amber while connecting, purple when no network is set.
 */
#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/gpio.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "tape.h"
#include "tapeio.h"
#include "led.h"
#include "link.h"
#include "netmgr.h"
#include "testtape.h"

#if CONFIG_IDF_TARGET_ESP32S3
/* ESP32-S3 SuperMini on the rev B carrier board */
#define PIN_RX      4
#define PIN_TX      6
#define PIN_PLAY    7
#define PIN_LED     48
#define LED_WS2812  true
#else
/* Classic ESP32 dev board for bench tests: BOOT button = PLAY */
#define PIN_RX      26
#define PIN_TX      25
#define PIN_PLAY    0
#define PIN_LED     2
#define LED_WS2812  false
#endif

#define TEST_TICKS    200           /* hold 2 s: tape test (10 ms ticks) */
#define FORGET_TICKS  500           /* hold 5 s: forget all saved Wi-Fi networks */

/* zx/menu, assembled by sjasmplus and embedded by main/CMakeLists.txt */
extern const uint8_t menu_tap_start[] asm("_binary_zxmenu_tap_start");
extern const uint8_t menu_tap_end[] asm("_binary_zxmenu_tap_end");

static const char *TAG = "zxmodem";

static volatile int64_t s_result_until;     /* show the RX result until then */
static volatile bool s_result_ok;

/* ---- RX: requests go to the link, anything else is logged ------------------ */

static void on_block(tape_dec_event_t ev, const uint8_t *b, size_t len)
{
    static bool code_hdr;                   /* last header was CODE 0,32 */
    const char *what = ev == TAPE_DEC_BLOCK_OK ? "checksum OK"
                     : ev == TAPE_DEC_OVERFLOW ? "TOO LONG (cut)" : "CHECKSUM BAD";

    s_result_ok = ev == TAPE_DEC_BLOCK_OK;
    s_result_until = esp_timer_get_time() + 2000000;
    if (ev == TAPE_DEC_BLOCK_OK && b[0] == 0x80) {
        link_post_request(b, len);
        return;
    }
    ESP_LOGI(TAG, "RX block: flag %02X, %u bytes, %s", b[0], (unsigned)len, what);
    if (ev != TAPE_DEC_BLOCK_OK)
        return;

    if (b[0] == 0x00 && len == 19) {
        static const char *types[] = { "Program", "Number array", "Character array", "Bytes" };
        unsigned dlen = b[12] | b[13] << 8, p1 = b[14] | b[15] << 8;
        ESP_LOGI(TAG, "  header: %s \"%.10s\", length %u, %s %u",
                 b[1] < 4 ? types[b[1]] : "?", (const char *)b + 2, dlen,
                 b[1] == 3 ? "start" : "autostart", p1);
        code_hdr = b[1] == 3 && dlen == 32 && p1 == 0;
        return;
    }
    ESP_LOG_BUFFER_HEXDUMP(TAG, b + 1, len - 2 > 64 ? 64 : len - 2, ESP_LOG_INFO);
    if (code_hdr && len == 34)
        ESP_LOGI(TAG, "  ROM bytes %s the 48K ROM: two-way link works!",
                 memcmp(b + 1, testtape_rom_start, sizeof testtape_rom_start) == 0
                     ? "match" : "DO NOT match");
    code_hdr = false;
}

/* ---- Main loop: button and LED -------------------------------------------- */

static void idle_led(int tick)
{
    net_status_t st;

    if (tick % 200 >= 5) {
        led_set(0, 0, 0);
        return;
    }
    netmgr_status(&st);
    if (st.state == NET_CONNECTED)
        led_set(0, 20, 0);
    else if (st.state == NET_CONNECTING)
        led_set(25, 12, 0);
    else
        led_set(15, 0, 20);
}

void app_main(void)
{
    static uint8_t test_tap[256];
    size_t test_len = testtape_build(test_tap, sizeof test_tap);
    gpio_config_t btn = {
        .pin_bit_mask = 1ULL << PIN_PLAY,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,   /* R18 pulls up too */
    };
    int held = 0, tick = 0;

    ESP_ERROR_CHECK(gpio_config(&btn));
    ESP_ERROR_CHECK(led_init(PIN_LED, LED_WS2812));
    ESP_ERROR_CHECK(tapeio_tx_init(PIN_TX));
    ESP_ERROR_CHECK(link_start());
    ESP_ERROR_CHECK(tapeio_rx_start(PIN_RX, on_block));
    ESP_ERROR_CHECK(netmgr_start());
    ESP_LOGI(TAG, "zxmodem %d.%d on %s: TX GPIO%d, RX GPIO%d, PLAY GPIO%d. "
             "Type LOAD \"\" on the Spectrum, then press PLAY "
             "(hold 2 s: tape test, 5 s: forget Wi-Fi).",
             FW_VERSION_MAJOR, FW_VERSION_MINOR, CONFIG_IDF_TARGET, PIN_TX, PIN_RX, PIN_PLAY);

    for (;; tick++, vTaskDelay(pdMS_TO_TICKS(10))) {
        /* PLAY is active low. Act on release, so the hold time picks the
         * action; 30 ms down counts as a press. */
        if (gpio_get_level(PIN_PLAY) == 0) {
            held++;
        } else {
            if (held >= FORGET_TICKS)
                netmgr_forget_all();
            else if (held >= TEST_TICKS)
                link_post_tape(test_tap, test_len, "tape test program");
            else if (held >= 3)
                link_post_tape(menu_tap_start, menu_tap_end - menu_tap_start, "ZX MODEM menu");
            held = 0;
        }

        /* While held, show what letting go would do: white after 2 s
         * (tape test), fast red after 5 s (forget Wi-Fi). */
        if (held >= FORGET_TICKS)
            led_set((tick / 10) % 2 ? 50 : 0, 0, 0);
        else if (held >= TEST_TICKS)
            led_set(30, 30, 30);
        else if (link_sending())
            led_set(0, 0, (tick / 25) % 2 ? 40 : 8);            /* blue, 2 Hz */
        else if (tapeio_rx_active())
            led_set(40, 30, 0);                                 /* yellow */
        else if (esp_timer_get_time() < s_result_until)
            s_result_ok ? led_set(0, 40, 0) : led_set(40, 0, 0);
        else
            idle_led(tick);
    }
}
