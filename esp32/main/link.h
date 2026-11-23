#ifndef LINK_H
#define LINK_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"

#define FW_VERSION_MAJOR 0
#define FW_VERSION_MINOR 8
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

/* For the services, on the link task only (docs/link-protocol.md 4.2, 5.2). */
enum { RESP_BODY = 0, RESP_ERROR = 1, RESP_URLINFO = 3, RESP_NETLIST = 4, RESP_WIFI = 5,
       RESP_OVERLAY = 6, RESP_INFO = 7 };
enum { LINK_TRUNCATED = 0x02 };     /* header flag: the modem cut the data */

/* One response, in chunks of up to 1024 bytes. field45 = header bytes 4-5
 * (the total length, or an app's load address); flags are ORed in. */
void link_send_ex(uint8_t type, const uint8_t *data, size_t len,
                  uint16_t http, uint16_t field45, uint8_t flags);
void link_send(uint8_t type, const uint8_t *data, size_t len, uint16_t http);
void link_send_error(const char *msg);
/* An error whose data starts with a service's code byte (1-31). */
void link_send_error_code(uint8_t code, const char *msg);
/* The same, with the HTTP status in the header (a refused type: the status
 * the server answered with, e.g. 404 with an HTML error page). */
void link_send_error_http(uint8_t code, const char *msg, uint16_t http);

/* The http service (svc_http.c). */
void svc_http(uint8_t cmd, const uint8_t *args, size_t nargs);

#endif
