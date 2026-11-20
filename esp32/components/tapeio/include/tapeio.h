/*
 * tapeio.h - ROM tape signal I/O for the ESP32.
 *
 * TX: one block at a time through the RMT peripheral, pulse by pulse from the
 *     portable tape encoder, so no block-sized symbol buffer is needed.
 * RX: a GPIO any-edge interrupt timestamps each edge with the CPU cycle
 *     counter; a task turns the gaps into T-states and feeds the portable
 *     decoder. A 20 ms silence ends a block.
 */
#ifndef TAPEIO_H
#define TAPEIO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"
#include "tape.h"

esp_err_t tapeio_tx_init(int gpio);

/* Play one block (flag, payload, checksum) incl. its trailing pause.
 * Blocks until the signal is out. */
esp_err_t tapeio_tx_block(const uint8_t *blk, size_t len, const tape_timing_t *tm);

/* Called from the RX task for every finished block. blk is only valid
 * during the call. */
typedef void (*tapeio_rx_cb_t)(tape_dec_event_t ev, const uint8_t *blk, size_t len);

/* Start the receiver: ISR and decode task pinned to core 1 (Wi-Fi will live
 * on core 0). */
esp_err_t tapeio_rx_start(int gpio, tapeio_rx_cb_t cb);

/* Ignore or accept edges. Off while we transmit: on a 48K, EAR and MIC share
 * a ULA pin, so our own signal echoes back on MIC. */
void tapeio_rx_enable(bool on);

/* True while the decoder is inside a pilot or a block. */
bool tapeio_rx_active(void);

#endif
