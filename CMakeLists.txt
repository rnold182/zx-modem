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
                --inc=${CMAKE_SOURCE_DIR}/sdk ${CMAKE_SOURCE_DIR}/zx/menu/main.asm
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
    add_custom_target(zx ALL DEPENDS ${MODEMTEST_TAP} ${ZXMENU_TAP} ${WIFISETUP_BIN} ${FETCHDEMO_TAP})
else()
    message(STATUS "sjasmplus not found: skipping zx/ targets (install it and re-run cmake)")
endif()
