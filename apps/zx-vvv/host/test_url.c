/* test_url.c - checks url.c against url_cases.txt (base | link | expected). */
#include <stdio.h>
#include <string.h>
#include "url.h"

static char *trim(char *s)
{
    char *e;

    while (*s == ' ' || *s == '\t')
        s++;
    e = s + strlen(s);
    while (e > s && (e[-1] == ' ' || e[-1] == '\t' || e[-1] == '\n' || e[-1] == '\r'))
        *--e = 0;
    return s;
}

int main(int argc, char **argv)
{
    static const char *names[] = { "", "SAME", "NOFOLLOW", "LONG" };
    char line[1024], out[2 * VVV_URL_MAX + 2];
    int n = 0, bad = 0;
    FILE *f;

    if (argc < 2 || !(f = fopen(argv[1], "r"))) {
        fprintf(stderr, "usage: test_url url_cases.txt\n");
        return 2;
    }
    while (fgets(line, sizeof line, f)) {
        char *base = line, *ref, *want, *got;
        int r;

        if (line[0] == '#' || !strchr(line, '|'))
            continue;
        ref = strchr(base, '|');
        *ref++ = 0;
        want = strchr(ref, '|');
        if (!want)
            continue;
        *want++ = 0;
        base = trim(base);
        ref = trim(ref);
        want = trim(want);
        r = vvv_url(base, ref, out, sizeof out);
        got = r == VVV_URL_OK ? out : (char *)names[r];
        n++;
        if (strcmp(got, want) != 0) {
            bad++;
            printf("FAIL: '%s' + '%s'\n  want %s\n  got  %s\n", base, ref, want, got);
        }
    }
    fclose(f);
    printf("url: %d/%d passed\n", n - bad, n);
    return bad != 0 || n == 0;
}
