#ifndef FETCH_H
#define FETCH_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"

typedef struct {
    size_t len;             /* body bytes in the buffer */
    int status;             /* final HTTP status */
    bool truncated;         /* the body was longer than the buffer */
} fetch_result_t;

/* GET url (http:// or https://; no scheme means http://), following up to
 * 5 redirects, into buf. On failure msg gets a short reason. */
esp_err_t fetch_get(const char *url, uint8_t *buf, size_t cap, fetch_result_t *res,
                    char *msg, size_t msg_size);

#endif
