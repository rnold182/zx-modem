# ESP-IDF project for the tape-port modem firmware.
# Build: idf.py set-target esp32s3 (PCB) or esp32 (WROOM-32), then idf.py build.
cmake_minimum_required(VERSION 3.16)

# Shared portable components (tape, later proto/fetch/translit) live at the
# repo root so the host tools build the same code.
set(EXTRA_COMPONENT_DIRS ${CMAKE_CURRENT_LIST_DIR}/../components)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(zxmodem)
