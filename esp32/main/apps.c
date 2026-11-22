/* apps.c - the registry of Spectrum apps in this firmware.
 *
 * Each app's code is assembled from apps/<name>/ and embedded by
 * main/CMakeLists.txt. To add one: build it there, embed it, add a line
 * here. Ids are permanent (the menu asks for an app by id); 1 is Wi-Fi setup
 * because firmware 0.3 already served it as overlay 1.
 */
#include "apps.h"

#define APP_ADDR 0xA000

extern const uint8_t wifisetup_start[] asm("_binary_wifisetup_bin_start");
extern const uint8_t wifisetup_end[] asm("_binary_wifisetup_bin_end");
extern const uint8_t vvv_start[] asm("_binary_vvv_bin_start");
extern const uint8_t vvv_end[] asm("_binary_vvv_bin_end");

static const app_t s_apps[] = {
    { 2, APP_KIND_APP,     "zx-vvv",            vvv_start, vvv_end, APP_ADDR },   /* apps/zx-vvv */
    { 3, APP_KIND_APP,     "Tape Loader (LAN)", NULL, NULL, APP_ADDR },
    { 1, APP_KIND_APP,     "Wi-Fi Setup",       wifisetup_start, wifisetup_end, APP_ADDR },
};

const app_t *apps_list(size_t *count)
{
    *count = sizeof s_apps / sizeof s_apps[0];
    return s_apps;
}

const app_t *apps_find(uint8_t id)
{
    for (size_t i = 0; i < sizeof s_apps / sizeof s_apps[0]; i++)
        if (s_apps[i].id == id)
            return &s_apps[i];
    return NULL;
}
