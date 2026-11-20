# Portable tape signal library (no ESP-IDF dependencies).
# Builds as an ESP-IDF component inside esp32/, and as a plain static library
# for the host tools.
set(TAPE_SRCS tape_block.c tape_enc.c tape_dec.c tapfile.c)

if(ESP_PLATFORM)
    idf_component_register(SRCS ${TAPE_SRCS} INCLUDE_DIRS include)
    return()
endif()

add_library(tape STATIC ${TAPE_SRCS})
target_include_directories(tape PUBLIC include)
