# Host build: portable tape library, host tools, tests, and (if sjasmplus is
# installed) the Spectrum programs. The ESP32 firmware is built separately
# with idf.py in esp32/.
cmake_minimum_required(VERSION 3.16)

# idf.py run from the repo root lands here; the firmware project is esp32/.
if(ESP_PLATFORM)
    message(FATAL_ERROR "This is the host build (tools and tests). For the "
                        "firmware, run idf.py inside the esp32 folder: cd esp32")
endif()
project(zxmodem C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

if(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
    add_compile_options(-Wall -Wextra)
endif()

enable_testing()

add_subdirectory(components/tape)
add_subdirectory(components/translit)
add_subdirectory(host)
add_subdirectory(apps/zx-vvv/host)

# --- Spectrum programs (sjasmplus) ------------------------------------------
find_program(SJASMPLUS sjasmplus
             HINTS $ENV{LOCALAPPDATA}/Programs/sjasmplus/sjasmplus-1.24.0.win)
if(SJASMPLUS)
    set(MODEMTEST_TAP ${CMAKE_BINARY_DIR}/modemtest.tap)
    add_custom_command(
        OUTPUT ${MODEMTEST_TAP}
        COMMAND ${SJASMPLUS} --nologo --inc=${CMAKE_SOURCE_DIR}/zx/lib
                ${CMAKE_SOURCE_DIR}/zx/modemtest/main.asm
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        DEPENDS ${CMAKE_SOURCE_DIR}/zx/modemtest/main.asm
        COMMENT "Assembling zx/modemtest -> modemtest.tap"
        VERBATIM)
    # The ZX MODEM menu and the Wi-Fi setup app (the firmware embeds its own
    # copies; these are for trying them in an emulator, e.g. with
    # host/tools/fake_reply.py). Apps build against sdk/ only.
    set(ZXMENU_TAP ${CMAKE_BINARY_DIR}/zxmenu.tap)
    set(WIFISETUP_BIN ${CMAKE_BINARY_DIR}/wifisetup.bin)
    file(GLOB ZX_LIB_SRCS ${CMAKE_SOURCE_DIR}/zx/lib/*.asm ${CMAKE_SOURCE_DIR}/sdk/*.inc)
    add_custom_command(
        OUTPUT ${ZXMENU_TAP}
        COMMAND ${SJASMPLUS} --nologo --inc=${CMAKE_SOURCE_DIR}/zx/lib
                --inc=${CMAKE_SOURCE_DIR}/sdk --lst=menu.lst --sym=menu.sym
                ${CMAKE_SOURCE_DIR}/zx/menu/main.asm
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        DEPENDS ${CMAKE_SOURCE_DIR}/zx/menu/main.asm ${ZX_LIB_SRCS}
        COMMENT "Assembling zx/menu -> zxmenu.tap"
        VERBATIM)
    add_custom_command(
        OUTPUT ${WIFISETUP_BIN}
        COMMAND ${SJASMPLUS} --nologo --inc=${CMAKE_SOURCE_DIR}/sdk
                ${CMAKE_SOURCE_DIR}/apps/wifisetup/wifisetup.asm
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        DEPENDS ${CMAKE_SOURCE_DIR}/apps/wifisetup/wifisetup.asm ${ZX_LIB_SRCS}
        COMMENT "Assembling apps/wifisetup -> wifisetup.bin"
        VERBATIM)
    # M2c demo: a BASIC program that fetches a page through the modem.
    set(FETCHDEMO_TAP ${CMAKE_BINARY_DIR}/fetchdemo.tap)
    add_custom_command(
        OUTPUT ${FETCHDEMO_TAP}
        COMMAND ${SJASMPLUS} --nologo ${CMAKE_SOURCE_DIR}/zx/basic/fetchdemo.asm
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        DEPENDS ${CMAKE_SOURCE_DIR}/zx/basic/fetchdemo.asm
        COMMENT "Assembling zx/basic/fetchdemo -> fetchdemo.tap"
        VERBATIM)
    # zx-vvv, the browser, and its URL self-test (cases from url_cases.txt).
    set(VVV_DIR ${CMAKE_SOURCE_DIR}/apps/zx-vvv)
    set(VVV_BIN ${CMAKE_BINARY_DIR}/vvv.bin)
    set(URLTEST_BIN ${CMAKE_BINARY_DIR}/urltest.bin)
    set(URL_CASES_INC ${CMAKE_BINARY_DIR}/url_cases.inc)
    find_package(Python3 COMPONENTS Interpreter REQUIRED)
    add_custom_command(
        OUTPUT ${VVV_BIN}
        COMMAND ${SJASMPLUS} --nologo --inc=${CMAKE_SOURCE_DIR}/sdk --inc=${VVV_DIR}/zx
                --lst=vvv.lst --sym=vvv.sym ${VVV_DIR}/zx/vvv.asm
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        DEPENDS ${VVV_DIR}/zx/vvv.asm ${VVV_DIR}/zx/url.asm ${VVV_DIR}/zx/render.asm
                ${VVV_DIR}/zx/style.asm ${VVV_DIR}/zx/forms.asm ${ZX_LIB_SRCS}
        COMMENT "Assembling apps/zx-vvv -> vvv.bin"
        VERBATIM)
    add_custom_command(
        OUTPUT ${URL_CASES_INC}
        COMMAND ${Python3_EXECUTABLE} ${VVV_DIR}/host/cases2asm.py
                ${VVV_DIR}/host/url_cases.txt ${URL_CASES_INC}
        DEPENDS ${VVV_DIR}/host/url_cases.txt ${VVV_DIR}/host/cases2asm.py
        COMMENT "Generating url_cases.inc"
        VERBATIM)
    add_custom_command(
        OUTPUT ${URLTEST_BIN}
        COMMAND ${SJASMPLUS} --nologo --inc=${CMAKE_SOURCE_DIR}/sdk --inc=${VVV_DIR}/zx
                --inc=${CMAKE_BINARY_DIR} ${VVV_DIR}/zx/urltest.asm
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        DEPENDS ${VVV_DIR}/zx/urltest.asm ${VVV_DIR}/zx/url.asm ${URL_CASES_INC} ${ZX_LIB_SRCS}
        COMMENT "Assembling apps/zx-vvv URL self-test -> urltest.bin"
        VERBATIM)
    # The fuzzer's code map (apps/zx-vvv/host/fuzz): rebuilt with the menu and
    # zx-vvv, so it never falls behind them.
    set(ZX_MAP ${CMAKE_BINARY_DIR}/zx.map)
    add_custom_command(
        OUTPUT ${ZX_MAP}
        COMMAND ${Python3_EXECUTABLE} ${VVV_DIR}/host/fuzz/mkmap.py ${ZX_MAP}
                ${CMAKE_BINARY_DIR}/menu.lst ${CMAKE_BINARY_DIR}/vvv.lst
        DEPENDS ${ZXMENU_TAP} ${VVV_BIN} ${VVV_DIR}/host/fuzz/mkmap.py
        COMMENT "Code map for zxfuzz -> zx.map"
        VERBATIM)
    add_custom_target(zx ALL DEPENDS ${MODEMTEST_TAP} ${ZXMENU_TAP} ${WIFISETUP_BIN} ${FETCHDEMO_TAP}
                      ${VVV_BIN} ${URLTEST_BIN} ${ZX_MAP})
else()
    message(STATUS "sjasmplus not found: skipping zx/ targets (install it and re-run cmake)")
endif()
