#ifndef FETCH_H
#define FETCH_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"

/* Why a fetch failed; the numbers are the http service's error codes
 * (docs/link-protocol.md 6.4). */
typedef enum {
    FETCH_OK = 0,
    FETCH_ERR_ADDRESS = 2,
    FETCH_ERR_CONNECT = 3,
    FETCH_ERR_TIMEOUT = 4,
    FETCH_ERR_REDIRECTS = 5,
    FETCH_ERR_REFUSED = 6,
} fetch_err_t;

typedef struct {
    const char *accept;     /* Accept header; NULL or "" = none */
    const char *refuse;     /* content types to refuse (see fetch_type_refused) */
} fetch_opts_t;

typedef struct {
    size_t len;             /* body bytes in the buffer */
    int status;             /* final HTTP status */
    bool truncated;         /* the body was longer than the buffer */
    fetch_err_t err;
    char ctype[64];         /* final content type, lower case, no parameters */
    const char *url;        /* final address after redirects (valid until the next fetch) */
} fetch_result_t;

/* GET url (http:// or https://; no scheme means http://), following up to
 * 5 redirects, into buf. A content type matching opts->refuse stops before
 * the body is read (FETCH_ERR_REFUSED, msg = the type). On failure res->err
 * says why and msg gets a short reason. opts may be NULL. */
esp_err_t fetch_get(const char *url, const fetch_opts_t *opts, uint8_t *buf, size_t cap,
                    fetch_result_t *res, char *msg, size_t msg_size);

/* True if type (lower case, no parameters) matches the space-separated list:
 * an entry ending in '/' matches by prefix, others the whole type. */
bool fetch_type_refused(const char *type, const char *list);

/* The shared body buffer for the services (one request at a time). */
uint8_t *fetch_buffer(size_t *cap);

#endif
