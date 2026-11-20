# Host tools and tests, built against the shared tape library.
add_executable(tap2wav tap2wav.c)
target_link_libraries(tap2wav PRIVATE tape)

add_executable(wav2tap wav2tap.c)
target_link_libraries(wav2tap PRIVATE tape)

add_subdirectory(tests)
