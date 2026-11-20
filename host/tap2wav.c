/*
 * tap2wav - render a .tap file as a WAV tape signal.
 * M0 stub: prints usage. Implemented in M1a.
 */
#include <stdio.h>
#include "tape.h"

int main(int argc, char **argv)
{
    (void)argc;
    fprintf(stderr,
            "usage: %s in.tap out.wav [--rate 44100] [--pause 1000] [--invert]\n"
            "(not implemented yet: M1a)\n",
            argv[0]);
    return 2;
}
