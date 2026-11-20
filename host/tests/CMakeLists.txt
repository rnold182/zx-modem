add_executable(test_smoke test_smoke.c)
target_link_libraries(test_smoke PRIVATE tape)
add_test(NAME smoke COMMAND test_smoke)

add_executable(test_tape test_tape.c)
target_link_libraries(test_tape PRIVATE tape)
add_test(NAME tape COMMAND test_tape ${CMAKE_CURRENT_SOURCE_DIR}/data/zx48k-save-test.wav)

# The firmware's PLAY test tape is portable C: check it here, and write it
# out as build/host/tests/esp32-testtape.tap for an emulator.
add_executable(test_testtape test_testtape.c ${CMAKE_SOURCE_DIR}/esp32/main/testtape.c)
target_include_directories(test_testtape PRIVATE ${CMAKE_SOURCE_DIR}/esp32/main)
target_link_libraries(test_testtape PRIVATE tape)
add_test(NAME testtape COMMAND test_testtape ${CMAKE_CURRENT_BINARY_DIR}/esp32-testtape.tap)

add_executable(test_translit test_translit.c)
target_link_libraries(test_translit PRIVATE translit)
add_test(NAME translit COMMAND test_translit)
