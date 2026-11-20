/* tapeio_rx.c - tape blocks in: edge timestamps -> portable decoder. */
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/gpio.h"
#include "esp_attr.h"
#include "esp_cpu.h"
#include "esp_rom_sys.h"
#include "tapeio.h"

#define RING        1024u       /* edges; ~250 ms of the fastest signal */
#define GAP_MS        20        /* silence that ends a block */
#define BLOCK_MAX   (64 * 1024 + 2)

static uint32_t s_ring[RING];
static volatile uint32_t s_head;
static volatile bool s_enabled;
static volatile bool s_reset;
static volatile bool s_active;
static TaskHandle_t s_task;
static tapeio_rx_cb_t s_cb;
static int s_gpio;

static void IRAM_ATTR edge_isr(void *arg)
{
    BaseType_t woken = pdFALSE;

    (void)arg;
    if (!s_enabled)
        return;
    s_ring[s_head % RING] = esp_cpu_get_cycle_count();
    s_head = s_head + 1;
    vTaskNotifyGiveFromISR(s_task, &woken);
    portYIELD_FROM_ISR(woken);
}

static void report(tape_dec_event_t ev, const tape_dec_t *d)
{
    if (ev != TAPE_DEC_NONE && s_cb)
        s_cb(ev, d->buf, d->len);
}

static void rx_task(void *arg)
{
    static uint8_t buf[BLOCK_MAX];
    tape_dec_t dec;
    uint32_t tail = 0, last = 0;
    bool have_last = false;
    /* The cycle counter runs at the CPU clock; T-states run at 3.5 MHz. */
    const uint32_t cpu_mhz = esp_rom_get_cpu_ticks_per_us();

    (void)arg;
    tape_dec_init(&dec, buf, sizeof buf);
    /* The ISR runs on the core that installs the service: this one. */
    gpio_install_isr_service(ESP_INTR_FLAG_IRAM);
    gpio_isr_handler_add(s_gpio, edge_isr, NULL);

    for (;;) {
        uint32_t woke = ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(GAP_MS));

        if (s_reset) {
            s_reset = false;
            tape_dec_init(&dec, buf, sizeof buf);
            tail = s_head;
            have_last = false;
        }
        while (tail != s_head) {
            uint32_t now = s_ring[tail % RING];
            tail++;
            if (have_last) {
                uint64_t t = (uint64_t)(now - last) * 7 / (2 * cpu_mhz);
                report(tape_dec_feed(&dec, t > UINT32_MAX ? UINT32_MAX : (uint32_t)t), &dec);
            }
            last = now;
            have_last = true;
        }
        if (!woke) {                        /* GAP_MS of silence */
            report(tape_dec_end(&dec), &dec);
            have_last = false;
        }
        s_active = dec.state != 0;          /* 0 = hunting for a pilot */
    }
}

esp_err_t tapeio_rx_start(int gpio, tapeio_rx_cb_t cb)
{
    gpio_config_t io = {
        .pin_bit_mask = 1ULL << gpio,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,  /* the comparator drives the pin */
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_ANYEDGE,
    };
    esp_err_t err = gpio_config(&io);

    if (err != ESP_OK)
        return err;
    s_gpio = gpio;
    s_cb = cb;
    s_enabled = true;
    if (xTaskCreatePinnedToCore(rx_task, "tape_rx", 4096, NULL, 10, &s_task, 1) != pdPASS)
        return ESP_ERR_NO_MEM;
    return ESP_OK;
}

void tapeio_rx_enable(bool on)
{
    if (on)
        s_reset = true;                     /* forget edges from before */
    s_enabled = on;
}

bool tapeio_rx_active(void)
{
    return s_active;
}
