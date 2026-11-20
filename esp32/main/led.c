/* led.c - status LED: the SuperMini's WS2812 RGB LED, or a plain LED on
 * other boards (any colour = on). */
#include "driver/gpio.h"
#include "driver/rmt_tx.h"
#include "driver/rmt_encoder.h"
#include "soc/soc_caps.h"
#include "led.h"

#define RES_HZ 10000000u                /* 0.1 us ticks */

static int s_gpio;
static bool s_rgb;
static rmt_channel_handle_t s_chan;
static rmt_encoder_handle_t s_enc;

esp_err_t led_init(int gpio, bool ws2812)
{
    s_gpio = gpio;
    s_rgb = ws2812;
    if (!ws2812) {
        gpio_reset_pin(gpio);
        return gpio_set_direction(gpio, GPIO_MODE_OUTPUT);
    }
    rmt_tx_channel_config_t cc = {
        .gpio_num = gpio,
        .clk_src = RMT_CLK_SRC_DEFAULT,
        .resolution_hz = RES_HZ,
        .mem_block_symbols = SOC_RMT_MEM_WORDS_PER_CHANNEL,
        .trans_queue_depth = 2,
    };
    /* WS2812 bits: 0 = 0.3 us high + 0.9 us low, 1 = 0.9 us high + 0.3 us low. */
    rmt_bytes_encoder_config_t bc = {
        .bit0 = { .level0 = 1, .duration0 = 3, .level1 = 0, .duration1 = 9 },
        .bit1 = { .level0 = 1, .duration0 = 9, .level1 = 0, .duration1 = 3 },
        .flags.msb_first = 1,
    };
    esp_err_t err = rmt_new_tx_channel(&cc, &s_chan);
    if (err == ESP_OK)
        err = rmt_new_bytes_encoder(&bc, &s_enc);
    if (err == ESP_OK)
        err = rmt_enable(s_chan);
    return err;
}

void led_set(uint8_t r, uint8_t g, uint8_t b)
{
    if (!s_rgb) {
        gpio_set_level(s_gpio, (r | g | b) != 0);
        return;
    }
    static uint8_t grb[3];                  /* WS2812 wants green first */
    rmt_transmit_config_t tc = { .loop_count = 0 };
    grb[0] = g;
    grb[1] = r;
    grb[2] = b;
    if (rmt_transmit(s_chan, s_enc, grb, sizeof grb, &tc) == ESP_OK)
        rmt_tx_wait_all_done(s_chan, 10);
}
