# z80.h (vendored)

A cycle-stepped Z80 emulator in one header, by Andre Weissflog, from
https://github.com/floooh/chips (`chips/z80.h`, commit
`7ef8776f637a6424ac615da64de6b968b06de791`), unchanged. zlib licence: see
`LICENSE`.

Used only by the host fuzzer `apps/zx-vvv/host/fuzz/zxfuzz.c`, which runs
zx-vvv's Z80 code in an emulated 48K.
