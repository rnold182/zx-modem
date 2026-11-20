/* tapeio_tx.c - tape blocks out through RMT. */
#include "driver/rmt_tx.h"
#include "driver/rmt_encoder.h"
#include "soc/soc_caps.h"
#include "tapeio.h"

#define TX_RES_HZ   10000000u   /* 0.1 us ticks: 7 T-states = 20 ticks */
#define MAX_TICKS   32767u      /* one RMT half-symbol (15 bits) */

/* Encoder state: the current pulse is cut into RMT half-symbols of at most
 * MAX_TICKS (only the 1 s pause needs cutting). */
typedef struct {
    tape_enc_t enc;
    uint32_t rest;      /* ticks left of the current pulse */
    uint8_t  level;     /* output level of the current pulse */
    bool     last;      /* the current pulse is the final pause */
} tx_state_t;

static rmt_channel_handle_t s_chan;
static rmt_encoder_handle_t s_encoder;
static tx_state_t s_tx;

static bool next_segment(tx_state_t *st, uint32_t *level, uint32_t *ticks)
{
    if (st->rest == 0) {
        tape_pulse_t p;
        if (st->last || !tape_enc_next(&st->enc, &p))
            return false;
        st->level ^= 1;                     /* every pulse starts with an edge */
        st->rest = (uint32_t)(((uint64_t)p.tstates * 20 + 3) / 7);
        st->last = p.pause;
    }
    *ticks = st->rest > MAX_TICKS ? MAX_TICKS : st->rest;
    st->rest -= *ticks;
    *level = st->level;
    return true;
}

/* RMT asks for up to symbols_free symbols; each symbol holds two segments. */
static size_t encode_cb(const void *data, size_t data_size, size_t symbols_written,
                        size_t symbols_free, rmt_symbol_word_t *symbols,
                        bool *done, void *arg)
{
    tx_state_t *st = arg;
    size_t n = 0;
    uint32_t l0, d0, l1, d1;

    (void)data; (void)data_size; (void)symbols_written;
    while (n < symbols_free) {
        if (!next_segment(st, &l0, &d0)) {
            *done = true;
            return n;
        }
        if (!next_segment(st, &l1, &d1)) {  /* odd count: pad, no edge */
            l1 = l0;
            d1 = 1;
        }
        symbols[n++] = (rmt_symbol_word_t){
            .level0 = l0, .duration0 = d0, .level1 = l1, .duration1 = d1,
        };
        if (st->last && st->rest == 0) {
            *done = true;
            return n;
        }
    }
    return n;
}

esp_err_t tapeio_tx_init(int gpio)
{
    rmt_tx_channel_config_t cc = {
        .gpio_num = gpio,
        .clk_src = RMT_CLK_SRC_DEFAULT,
        .resolution_hz = TX_RES_HZ,
        .mem_block_symbols = SOC_RMT_MEM_WORDS_PER_CHANNEL,
        .trans_queue_depth = 2,
    };
    rmt_simple_encoder_config_t ec = {
        .callback = encode_cb,
        .arg = &s_tx,
        .min_chunk_size = 2,
    };
    esp_err_t err = rmt_new_tx_channel(&cc, &s_chan);
    if (err == ESP_OK)
        err = rmt_new_simple_encoder(&ec, &s_encoder);
    if (err == ESP_OK)
        err = rmt_enable(s_chan);
    return err;
}

esp_err_t tapeio_tx_block(const uint8_t *blk, size_t len, const tape_timing_t *tm)
{
    rmt_transmit_config_t tc = { .loop_count = 0, .flags.eot_level = 0 };
    esp_err_t err;

    tape_enc_init(&s_tx.enc, tm, blk, len);
    s_tx.rest = 0;
    s_tx.level = 0;
    s_tx.last = false;
    /* The simple encoder reads our state through its arg, not the payload. */
    err = rmt_transmit(s_chan, s_encoder, &s_tx, sizeof s_tx, &tc);
    if (err == ESP_OK)
        err = rmt_tx_wait_all_done(s_chan, -1);
    return err;
}
