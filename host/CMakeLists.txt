# Host tools and tests, built against the shared tape library.
add_executable(tap2wav tap2wav.c)
target_link_libraries(tap2wav PRIVATE tape)

add_executable(wav2tap wav2tap.c)
target_link_libraries(wav2tap PRIVATE tape)

# zxfuzz: runs zx-vvv's own code in an emulated 48K, for fuzzing (M6).
add_executable(zxfuzz ${CMAKE_SOURCE_DIR}/apps/zx-vvv/host/fuzz/zxfuzz.c)
target_include_directories(zxfuzz PRIVATE ${CMAKE_SOURCE_DIR}/host/third_party/chips)
target_compile_options(zxfuzz PRIVATE -O2)

add_subdirectory(tests)
