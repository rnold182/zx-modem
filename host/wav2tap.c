/*
 * wav2tap - decode a recorded tape signal (WAV) into a .tap file.
 * M0 stub: prints usage. Implemented in M1a.
 */
#include <stdio.h>
#include "tape.h"

int main(int argc, char **argv)
{
    (void)argc;
    fprintf(stderr,
            "usage: %s in.wav out.tap [--channel 0]\n"
            "(not implemented yet: M1a)\n",
            argv[0]);
    return 2;
}
