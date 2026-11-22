#ifndef APPS_H
#define APPS_H

#include <stddef.h>
#include <stdint.h>

/* The Spectrum apps the modem offers (docs/app-api.md). The menu lists them
 * from the system V reply and fetches one with system O <id>. */
typedef enum {
    APP_KIND_APP = 1,       /* loads at APP_ADDR, CALLed, returns to the menu */
    APP_KIND_PROGRAM = 2,   /* replaces the menu (not yet supported) */
} app_kind_t;

typedef struct {
    uint8_t id;
    uint8_t kind;           /* app_kind_t */
    const char *name;       /* menu text, at most 24 characters */
    const uint8_t *code;    /* NULL: listed but not available yet */
    const uint8_t *code_end;
    uint16_t addr;          /* load address */
} app_t;

const app_t *apps_list(size_t *count);
const app_t *apps_find(uint8_t id);

#endif
