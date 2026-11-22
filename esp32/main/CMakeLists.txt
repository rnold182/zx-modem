idf_component_register(SRCS "main.c" "led.c" "testtape.c" "link.c" "netmgr.c" "fetch.c" "apps.c" "svc_http.c"
                       INCLUDE_DIRS "."
                       REQUIRES tape tapeio translit esp_driver_gpio esp_driver_rmt esp_timer
                                esp_wifi esp_netif esp_event nvs_flash lwip
                                esp_http_client mbedtls)

# The Spectrum side, assembled here and embedded in the firmware:
#  - the ZX MODEM menu (zx/menu) as a tape image, _binary_zxmenu_tap_*; PLAY sends it
#  - the apps (apps/*), _binary_<name>_bin_*; system O <id> sends one (apps.c)
# Apps build against sdk/ only (the API contract), never against the menu.
set(REPO_DIR ${CMAKE_CURRENT_LIST_DIR}/../..)
set(ZX_DIR ${REPO_DIR}/zx)
set(SDK_DIR ${REPO_DIR}/sdk)
find_program(SJASMPLUS sjasmplus
             HINTS $ENV{LOCALAPPDATA}/Programs/sjasmplus/sjasmplus-1.24.0.win)
if(NOT SJASMPLUS)
    message(FATAL_ERROR "sjasmplus not found: install it (see README) to build the menu")
endif()
set(ZX_OUT ${CMAKE_CURRENT_BINARY_DIR})
set(MENU_TAP ${ZX_OUT}/zxmenu.tap)
set(WIFI_BIN ${ZX_OUT}/wifisetup.bin)
set(VVV_BIN ${ZX_OUT}/vvv.bin)
set(VVV_DIR ${REPO_DIR}/apps/zx-vvv/zx)
file(GLOB ZX_LIB_SRCS ${ZX_DIR}/lib/*.asm ${SDK_DIR}/*.inc)
add_custom_command(
    OUTPUT ${MENU_TAP}
    COMMAND ${SJASMPLUS} --nologo --inc=${ZX_DIR}/lib --inc=${SDK_DIR} ${ZX_DIR}/menu/main.asm
    WORKING_DIRECTORY ${ZX_OUT}
    DEPENDS ${ZX_DIR}/menu/main.asm ${ZX_LIB_SRCS}
    COMMENT "Assembling zx/menu -> zxmenu.tap"
    VERBATIM)
add_custom_command(
    OUTPUT ${WIFI_BIN}
    COMMAND ${SJASMPLUS} --nologo --inc=${SDK_DIR} ${REPO_DIR}/apps/wifisetup/wifisetup.asm
    WORKING_DIRECTORY ${ZX_OUT}
    DEPENDS ${REPO_DIR}/apps/wifisetup/wifisetup.asm ${ZX_LIB_SRCS}
    COMMENT "Assembling apps/wifisetup -> wifisetup.bin"
    VERBATIM)
add_custom_command(
    OUTPUT ${VVV_BIN}
    COMMAND ${SJASMPLUS} --nologo --inc=${SDK_DIR} --inc=${VVV_DIR} ${VVV_DIR}/vvv.asm
    WORKING_DIRECTORY ${ZX_OUT}
    DEPENDS ${VVV_DIR}/vvv.asm ${VVV_DIR}/url.asm ${VVV_DIR}/render.asm ${ZX_LIB_SRCS}
    COMMENT "Assembling apps/zx-vvv -> vvv.bin"
    VERBATIM)
add_custom_target(zxprograms DEPENDS ${MENU_TAP} ${WIFI_BIN} ${VVV_BIN})
target_add_binary_data(${COMPONENT_LIB} ${MENU_TAP} BINARY DEPENDS zxprograms)
target_add_binary_data(${COMPONENT_LIB} ${WIFI_BIN} BINARY DEPENDS zxprograms)
target_add_binary_data(${COMPONENT_LIB} ${VVV_BIN} BINARY DEPENDS zxprograms)
