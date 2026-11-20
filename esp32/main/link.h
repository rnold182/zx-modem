#ifndef LINK_H
#define LINK_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"

#define FW_VERSION_MAJOR 0
#define FW_VERSION_MINOR 6
#define PROTO_VERSION    1

/* The tape task: the only user of the transmitter. It answers requests and
 * plays tapes, one job at a time, with the receiver off while it sends. */
esp_err_t link_start(void);

/* A request block (flag 0x80, payload, checksum) arrived from the Spectrum. */
void link_post_request(const uint8_t *blk, size_t len);

/* Play a .tap image as a plain ROM tape. The image must stay valid. */
void link_post_tape(const uint8_t *tap, size_t len, const char *name);

/* True while the transmitter is busy. */
bool link_sending(void);

#endif
