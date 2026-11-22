# zx-vvv host tests: the C reference of the browser's address rules.
add_executable(test_url test_url.c url.c)
add_test(NAME url COMMAND test_url ${CMAKE_CURRENT_SOURCE_DIR}/url_cases.txt)
