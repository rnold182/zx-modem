#ifndef NETMGR_H
#define NETMGR_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>
#include "esp_err.h"

typedef enum {
    NET_NOT_SET_UP = 0,     /* no saved network */
    NET_CONNECTING = 1,
    NET_CONNECTED = 2,
} net_state_t;

typedef struct {
    net_state_t state;
    uint8_t ip[4];
    int8_t rssi;
    char ssid[33];          /* the network in use or being tried */
    bool clock_valid;
    struct tm local;        /* local time, valid if clock_valid */
} net_status_t;

typedef struct {
    char ssid[33];          /* raw, as the access point sends it */
    int8_t rssi;
    uint8_t authmode;       /* wifi_auth_mode_t; 0 = open */
    bool saved;
    bool connected;
} net_ap_t;

#define NET_SCAN_MAX  19    /* the setup screen has 19 rows plus "Other..." */
#define NET_SAVED_MAX 5

/* Start Wi-Fi and NTP. The modem then keeps itself on the strongest saved
 * network in range (or the menuconfig one while nothing is saved). */
esp_err_t netmgr_start(void);

void netmgr_status(net_status_t *st);

/* Scan; fills the list strongest first, one entry per network name, and
 * keeps it for the *_index calls. Returns the count, or -1 on error. */
int netmgr_scan(const net_ap_t **list);

/* The last scan with fresh saved/connected marks (after a forget). */
int netmgr_last_scan(const net_ap_t **list);

/* Join a network from the last scan, or by name. Blocks up to ~15 s. An
 * empty password for a saved network means "use the saved one". On success
 * the network is saved (most recent first); on failure msg gets a short
 * reason and the modem goes back to its saved networks. */
esp_err_t netmgr_join_index(int index, const char *password, char *msg, size_t msg_size);
esp_err_t netmgr_join(const char *ssid, const char *password, char *msg, size_t msg_size);

/* Forget the saved network of scan entry index / all saved networks. */
esp_err_t netmgr_forget_index(int index);
void netmgr_forget_all(void);

#endif
