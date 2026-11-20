/* test_translit - UTF-8 -> ASCII conversion (components/translit). */
#include <stdio.h>
#include <string.h>
#include "translit.h"

static int failures;

static void expect(const char *in, const char *want)
{
    char buf[256];
    size_t n = strlen(in);

    memcpy(buf, in, n);
    n = translit_utf8((unsigned char *)buf, n);
    buf[n] = 0;
    if (strcmp(buf, want) != 0) {
        fprintf(stderr, "translit(\"%s\") = \"%s\", want \"%s\"\n", in, buf, want);
        failures++;
    }
}

int main(void)
{
    expect("plain ASCII 123 ~!", "plain ASCII 123 ~!");
    expect("line\r\nnext\ttab", "line\r\nnext\ttab");
    expect("bell\x07 del\x7f", "bell del?");
    /* Hungarian */
    expect("\xc3\xa1rv\xc3\xadzt\xc5\xb1r\xc5\x91 t\xc3\xbck\xc3\xb6rf\xc3\xbar\xc3\xb3g\xc3\xa9p",
           "arvizturo tukorfurogep");
    expect("\xc3\x81RV\xc3\x8dZT\xc5\xb0R\xc5\x90", "ARVIZTURO");
    /* other Latin */
    expect("Stra\xc3\x9f" "e \xc3\x86sop \xc5\x92uvre \xc3\xa7" "a \xc5\x81\xc3\xb3" "d\xc5\xba",
           "Strasse AEsop OEuvre ca Lodz");
    /* punctuation */
    expect("\xe2\x80\x9cquoted\xe2\x80\x9d \xe2\x80\x98it\xe2\x80\x99s\xe2\x80\x99",
           "\"quoted\" 'it's'");
    expect("a\xe2\x80\x93" "b\xe2\x80\x94" "c\xe2\x80\xa6", "a-b-c...");
    expect("+7\xc2\xb0" "C \xe2\x86\x93" "11km/h", "+7 C v11km/h");
    expect("10\xc2\xa0\xe2\x82\xac", "10 EUR");
    /* wttr.in style: emoji + variation selector -> one ? */
    expect("Budapest: \xe2\x9b\x85\xef\xb8\x8f  +7\xc2\xb0" "C", "Budapest: ?  +7 C");
    expect("\xf0\x9f\x98\x80!", "?!");
    expect("\xef\xbb\xbf" "BOM", "BOM");
    /* broken UTF-8 */
    expect("a\x80" "b", "a?b");
    expect("cut\xc3", "cut?");
    expect("bad\xe2\x82" "x", "bad?" "?" "x");

    if (failures == 0)
        printf("translit: OK\n");
    return failures ? 1 : 0;
}
