# UTF-8 -> ASCII for the Spectrum (no ESP-IDF dependencies): an ESP-IDF
# component inside esp32/, a plain static library for the host tests.
if(ESP_PLATFORM)
    idf_component_register(SRCS translit.c INCLUDE_DIRS include)
    return()
endif()

add_library(translit STATIC translit.c)
target_include_directories(translit PUBLIC include)
