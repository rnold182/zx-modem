/* zxfuzz.c - run zx-vvv's own Z80 code in an emulated 48K, for fuzzing (M6).
 *
 * The real 48K ROM boots, the ZX MODEM menu and vvv.bin are loaded where
 * they live, and zx-vvv is started as the menu starts it. Two things are
 * played by this program instead of real hardware, at the menu's API table:
 *   - the modem: link_request is noted, link_receive gets a made-up reply
 *     (the page under test, its stylesheets, errors, broken replies);
 *   - the keyboard: wait_key gets keys from a script (links, screens, the
 *     link list, Back, Reload, the address field ... then Q).
 * Everything else is zx-vvv's and the menu's real code. A seed decides the
 * replies and the keys, so every run can be repeated exactly.
 *
 * A run fails if the CPU
 *   - runs anything but an instruction start of the menu or zx-vvv, or the ROM
 *     (a jump into data or a broken return address);
 *   - writes to an instruction, the ROM, the API table, the UDGs, or memory
 *     outside the screen, the system variables, the stack and the app's areas;
 *   - takes the stack below STACK_LOW;
 *   - runs more than HANG_T T-states without asking for a key (a hang);
 *   - asks the modem to load into memory outside the app's areas.
 *
 *   zxfuzz run   PAGE [--site SHEET] [--sheet SHEET] [--seed N] [-v]
 *   zxfuzz fuzz  CORPUS_DIR COUNT SEED OUT_DIR
 *   zxfuzz render PAGE OUT.scr       (every screen of the page, 6912 bytes each)
 * Files: --rom (default Fuse's 48.rom), --build DIR (zxmenu.tap, vvv.bin,
 * vvv.sym, zx.map; default "build").
 */
#define CHIPS_IMPL
#include "z80.h"

#include <ctype.h>
#include <dirent.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

/* ---- The menu's API table (sdk/zxmodem_api.inc) ---------------------- */
#define API_LINK_REQUEST 32823
#define API_LINK_RECEIVE 32826
#define API_GET_KEY      32829
#define API_WAIT_KEY     32832
#define API_EDIT_LINE    32841
#define API_END          32847
#define LINK_HEADER      32786
#define APP_ADDR         0xA000
#define APP_END          0xFF58
#define APP_SPARE        0x9000

#define SENTINEL   0xFFF0          /* zx-vvv's return address: back to "the menu" */
#define STACK_TOP  0x7FF8
#define STACK_LOW  0x7C00          /* 1 KB of stack is more than plenty */
#define FRAME_T    69888
#define HANG_T     400000000ull    /* ~2 minutes of Spectrum time per key */
#define MAX_KEYS   60

#define K_EDIT 7
#define K_LEFT 8
#define K_RIGHT 9
#define K_DOWN 10
#define K_UP 11
#define K_DELETE 12
#define K_ENTER 13
#define K_CLEAR 4                  /* CAPS+3 */

static uint8_t mem[65536];
static uint8_t base_mem[65536];    /* after boot and load */
static uint8_t cmap[65536];        /* 1 code byte, 3 instruction start */
static uint8_t wok[65536];         /* 1 = may be written */
static char build_dir[512] = "build";
static char rom_path[512];
static int verbose;

/* zx-vvv symbols */
static uint16_t sym_page_buf, sym_code_end, sym_screens, sym_page_no, sym_show_page,
                sym_new_page;

static void die(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(2);
}

static long read_file(const char *path, uint8_t *buf, long max)
{
    FILE *f = fopen(path, "rb");
    long n;
    if (!f)
        return -1;
    n = (long)fread(buf, 1, (size_t)max, f);
    fclose(f);
    return n;
}

static void write_file(const char *path, const uint8_t *buf, long n)
{
    FILE *f = fopen(path, "wb");
    if (!f)
        die("can't write %s", path);
    fwrite(buf, 1, (size_t)n, f);
    fclose(f);
}

/* ---- The machine ------------------------------------------------------- */

static z80_t cpu;
static uint64_t pins;
static uint64_t tstates;
static uint64_t next_frame;

/* What went wrong (empty while all is well). */
static char failure[256];
static uint16_t trace[64];         /* the last instruction addresses */
static unsigned trace_n;
static int checking;               /* 0 while booting */

static void fail(const char *fmt, ...)
{
    va_list ap;
    if (failure[0])
        return;
    va_start(ap, fmt);
    vsnprintf(failure, sizeof failure, fmt, ap);
    va_end(ap);
}

static void tick(void)
{
    if (tstates >= next_frame) {                 /* the ULA's 50 Hz interrupt */
        pins |= Z80_INT;
        if (tstates >= next_frame + 32) {
            pins &= ~Z80_INT;
            next_frame += FRAME_T;
        }
    }
    pins = z80_tick(&cpu, pins);
    tstates++;
    if (pins & Z80_MREQ) {
        uint16_t a = Z80_GET_ADDR(pins);
        if (pins & Z80_RD) {
            Z80_SET_DATA(pins, mem[a]);
        } else if (pins & Z80_WR) {
            if (checking && !wok[a])
                fail("write %02X to %04X", Z80_GET_DATA(pins), a);
            if (a >= 0x4000)
                mem[a] = Z80_GET_DATA(pins);
        }
    } else if (pins & Z80_IORQ) {
        if (pins & (Z80_M1 | Z80_RD)) {              /* IM 1; no keys, no tape */
            Z80_SET_DATA(pins, 0xFF);
        }
    }
}

/* Run one instruction (to the next instruction boundary). */
static void step(void)
{
    do
        tick();
    while (!z80_opdone(&cpu));
}

static uint16_t pop16(void)
{
    uint16_t v = (uint16_t)(mem[cpu.sp] | (mem[(uint16_t)(cpu.sp + 1)] << 8));
    cpu.sp += 2;
    return v;
}

static void push16(uint16_t v)
{
    cpu.sp -= 2;
    mem[cpu.sp] = (uint8_t)v;
    mem[(uint16_t)(cpu.sp + 1)] = (uint8_t)(v >> 8);
}

/* The CPU stops at instruction boundaries: z80_opdone() is true in the
 * opcode fetch (M1) of the next instruction, so its address is the one on
 * the address bus (cpu.pc has moved on already). */
static uint16_t next_pc(void)
{
    return Z80_GET_ADDR(pins);
}

/* Go on at pc: the fetch at the old address is dropped. */
static void jump(uint16_t pc)
{
    pins = z80_prefetch(&cpu, pc);
    step();
}

/* ---- Loading ------------------------------------------------------------ */

static void load_menu(void)
{
    static uint8_t tap[65536];
    char path[600];
    long n, off = 0;
    int code_next = 0;
    uint16_t start = 0;

    snprintf(path, sizeof path, "%s/zxmenu.tap", build_dir);
    n = read_file(path, tap, sizeof tap);
    if (n < 0)
        die("no %s", path);
    while (off + 2 <= n) {
        long len = tap[off] | (tap[off + 1] << 8);
        uint8_t *b = tap + off + 2;
        if (len >= 19 && b[0] == 0 && b[1] == 3) {   /* a CODE header */
            start = (uint16_t)(b[14] | (b[15] << 8));
            code_next = 1;
        } else if (code_next && b[0] == 0xFF) {
            memcpy(mem + start, b + 1, (size_t)(len - 2));
            code_next = 0;
        }
        off += 2 + len;
    }
    if (!start)
        die("no code block in %s", path);
}

static uint16_t sym(const char *name)
{
    char path[600], line[512];
    FILE *f;
    size_t nl = strlen(name);

    snprintf(path, sizeof path, "%s/vvv.sym", build_dir);
    f = fopen(path, "r");
    if (!f)
        die("no %s", path);
    while (fgets(line, sizeof line, f)) {
        if (!strncmp(line, name, nl) && line[nl] == ':') {
            char *p = strstr(line, "0x");
            fclose(f);
            if (!p)
                break;
            return (uint16_t)strtoul(p, NULL, 16);
        }
    }
    die("symbol %s not found", name);
    return 0;
}

static void allow(unsigned from, unsigned to, int ok)
{
    for (unsigned a = from; a < to && a < 65536; a++)
        wok[a] = (uint8_t)ok;
}

static void setup(void)
{
    char path[600];

    if (!rom_path[0]) {
        const char *la = getenv("LOCALAPPDATA");
        snprintf(rom_path, sizeof rom_path, "%s/Programs/fuse/roms/48.rom", la ? la : ".");
    }
    if (read_file(rom_path, mem, 16384) != 16384)
        die("no 48K ROM at %s (--rom)", rom_path);

    /* Boot the ROM for 3 s: system variables as on a real 48K. */
    pins = z80_init(&cpu);
    tstates = 0;
    next_frame = FRAME_T;
    while (tstates < 150ull * FRAME_T)
        tick();

    load_menu();
    snprintf(path, sizeof path, "%s/vvv.bin", build_dir);
    if (read_file(path, mem + APP_ADDR, APP_END - APP_ADDR) <= 0)
        die("no %s", path);
    snprintf(path, sizeof path, "%s/zx.map", build_dir);
    if (read_file(path, cmap, sizeof cmap) != 65536)
        die("no %s (python apps/zx-vvv/host/fuzz/mkmap.py build/zx.map build/menu.lst build/vvv.lst)", path);
    memcpy(base_mem, mem, sizeof mem);

    sym_page_buf = sym("page_buf");
    sym_code_end = sym("code_end");
    sym_screens = sym("screens");
    sym_page_no = sym("page_no");
    sym_show_page = sym("show_page");
    sym_new_page = sym("new_page");

    /* Where writes are fine: the screen, the printer buffer (the line
     * buffer), the system variables, the stack, the menu's variables and
     * the app's memory. Not: the ROM, BASIC, the API table, instructions,
     * the UDGs. */
    allow(0x4000, 0x5D00, 1);
    allow(STACK_LOW, 0x8000, 1);
    allow(0x8000, API_END, 0);
    allow(32777, 32796, 1);                          /* basic_*, scr_*, link_header */
    allow(API_END, APP_END, 1);
    for (unsigned a = 0x8000; a < 65536; a++)
        if (cmap[a])
            wok[a] = 0;
}

/* ---- Random numbers (xorshift, seeded per run) -------------------------- */

static uint64_t rng;

static uint32_t rnd(void)
{
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return (uint32_t)(rng >> 32);
}

static unsigned rn(unsigned n) { return n ? rnd() % n : 0; }

/* ---- One run: zx-vvv with a page, its sheets, scripted keys and replies -- */

typedef struct {
    const uint8_t *page; long page_len;
    const uint8_t *site; long site_len;              /* NULL: none (404) */
    const uint8_t *sheet; long sheet_len;
    uint64_t seed;
} run_t;

static const run_t *cur;
static int keys_sent;
static int in_field;                                 /* last key opened the address field */

static void log_v(const char *fmt, ...)
{
    va_list ap;
    if (!verbose)
        return;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
}

/* The next key, from the seed. Mostly browsing keys; sometimes the address
 * field, the link list, help; Q at the end. */
static uint8_t next_key(void)
{
    static const uint8_t browse[] = {
        '6', '7', K_DOWN, K_UP, '6', '6', '7', 'n', 'm', 'n', K_ENTER, 'b',
        'l', 'r', 'h', '?', 'g', 'N', 'M', 'L', 'x', ' ', K_EDIT, '6', '7' };
    static const uint8_t field[] = {
        'a', 'z', '/', '.', ':', '#', '@', '?', ' ', '~', K_LEFT, K_RIGHT, K_DELETE,
        K_CLEAR, K_ENTER, K_EDIT, K_LEFT, K_DELETE, '1', 'h' };
    uint8_t k;

    keys_sent++;
    if (keys_sent > MAX_KEYS)                        /* Q, or out of a field first */
        return (keys_sent & 1) ? 'q' : K_EDIT;
    if (in_field) {
        k = field[rn(sizeof field)];
        if (rn(20) == 0)                             /* a long run of one key */
            in_field = 2;
        if (k == K_ENTER || k == K_EDIT)
            in_field = 0;
        return k;
    }
    k = browse[rn(sizeof browse)];
    if (k == 'g')
        in_field = 1;
    return k;
}

/* The modem's reply to a request in memory at HL, BC bytes, loaded at IX,
 * at most DE bytes. */
static uint8_t req_buf[512];                         /* the last request */
static unsigned req_len;

static void modem_request(void)
{
    uint16_t hl = cpu.hl, bc = cpu.bc;

    if (hl < 0x5B00 || (unsigned)hl + bc > APP_END || bc > 320 || bc < 5)   /* docs/link-protocol.md: 320 */
        fail("link_request from %04X, %u bytes", hl, bc);
    req_len = bc < sizeof req_buf ? bc : sizeof req_buf - 1;
    memcpy(req_buf, mem + hl, req_len);
    req_buf[req_len] = 0;
}

static void modem_reply(void)
{
    static uint8_t data[70000];
    uint16_t ix = cpu.ix, room = cpu.de;
    unsigned max = 0, n = 0, i;
    int type = 0, status = 200, flags = 1, nc = 0, is_sheet = 0;
    const uint8_t *body = NULL;
    long body_len = 0;
    char url[300];

    /* the request: 01 'G' flags max:2 url 0 accept 0 refuse */
    if (req_len < 5 || req_buf[0] != 0x01 || req_buf[1] != 'G')
        fail("link_receive without an http G request");
    for (i = 0; i < sizeof url - 1 && 5 + i < req_len && req_buf[5 + i]; i++)
        url[i] = (char)req_buf[5 + i];
    url[i] = 0;
    max = req_buf[3] | (req_buf[4] << 8);
    is_sheet = strlen(url) > 4 && !strcmp(url + strlen(url) - 4, ".8ss");
    log_v("  request %s%s (max %u, into %04X, %u bytes)\n", url, is_sheet ? " [sheet]" : "",
          max, ix, room);

    /* zx-vvv may only load into its own memory */
    if (ix < APP_SPARE || (unsigned)ix + room > APP_END)
        fail("link_receive into %04X, %u bytes", ix, room);

    if (is_sheet) {
        int site = strstr(url, "/site.8ss") != NULL;
        body = site ? cur->site : cur->sheet;
        body_len = site ? cur->site_len : cur->sheet_len;
        if (!body || rn(8) == 0) {
            status = 404;
            body = (const uint8_t *)"Not found\n";
            body_len = 10;
        }
    } else {
        body = cur->page;
        body_len = cur->page_len;
        if (rn(12) == 0)
            status = 404;
    }
    switch (rn(14)) {                                /* now and then: trouble */
    case 0:
        type = 1;
        n = (unsigned)snprintf((char *)data, sizeof data, "%cSomething went wrong", 1 + rn(8));
        break;
    case 1: nc = 1 + rn(4); break;                   /* tape error, BREAK, too long */
    case 2: type = rn(9); break;                     /* another type */
    default: break;
    }
    if (!nc && type != 1) {
        /* url 0 type 0 body: the final address is the asked one, sometimes not */
        const char *fin = url;
        static char odd[300];
        switch (rn(16)) {
        case 0: fin = "https://t8wn.com/@x/"; break;
        case 1:
            memset(odd, 'a', 290);
            memcpy(odd, "http://", 7);
            odd[290] = 0;
            fin = odd;
            break;
        case 2: fin = ""; break;
        case 3: fin = "x:y@z:99999/../..?#"; break;
        default: break;
        }
        n = (unsigned)strlen(fin);
        memcpy(data, fin, n);
        data[n++] = 0;
        memcpy(data + n, is_sheet ? "text/plain" : "text/8tml", is_sheet ? 10 : 9);
        n += is_sheet ? 10 : 9;
        data[n++] = 0;
        if ((unsigned long)body_len > max) {         /* the modem cuts at max */
            body_len = max;
            flags |= 2;
        }
        if (n + body_len > sizeof data)
            body_len = (long)(sizeof data - n);
        memcpy(data + n, body, (size_t)body_len);
        n += (unsigned)body_len;
    }
    if (!nc && n > room)
        nc = 3;                                      /* LINK_ERR_TOO_LONG */
    if (nc) {
        log_v("  reply: link error %d\n", nc);
        cpu.a = (uint8_t)nc;
        cpu.f &= ~Z80_CF;
        return;
    }
    memcpy(mem + ix, data, n);                       /* (ix + n <= APP_END: checked) */
    mem[LINK_HEADER + 0] = (uint8_t)type;
    mem[LINK_HEADER + 1] = (uint8_t)flags;
    mem[LINK_HEADER + 2] = (uint8_t)n;
    mem[LINK_HEADER + 3] = (uint8_t)(n >> 8);
    mem[LINK_HEADER + 4] = (uint8_t)n;
    mem[LINK_HEADER + 5] = (uint8_t)(n >> 8);
    mem[LINK_HEADER + 6] = 0;
    mem[LINK_HEADER + 7] = 1;
    mem[LINK_HEADER + 8] = (uint8_t)status;
    mem[LINK_HEADER + 9] = (uint8_t)(status >> 8);
    log_v("  reply: type %d, status %d, %u bytes\n", type, status, n);
    cpu.a = (uint8_t)type;
    cpu.bc = (uint16_t)n;
    cpu.f |= Z80_CF;
}

static void reset_machine(void)
{
    memcpy(mem, base_mem, sizeof mem);
    pins = z80_init(&cpu);
    cpu.iy = 0x5C3A;                                 /* as BASIC leaves it */
    cpu.im = 1;
    cpu.iff1 = cpu.iff2 = true;
    cpu.sp = STACK_TOP;
    tstates = 0;
    next_frame = FRAME_T;
    failure[0] = 0;
    trace_n = 0;
    checking = 1;
}

/* Run until PC reaches `until` (or the run fails). The API calls are
 * played here. Returns 0 when it got there. */
static int run_to(uint16_t until)
{
    uint64_t since_key = tstates;

    while (!failure[0]) {
        uint16_t pc = next_pc();

        if (pc == until)
            return 0;
        if (pc == API_WAIT_KEY || pc == API_GET_KEY) {
            uint8_t k = next_key();
            log_v("key %d: %s%c (%d)\n", keys_sent, k < 32 ? "^" : "", k < 32 ? k + 64 : k, k);
            cpu.a = k;
            since_key = tstates;
            jump(pop16());
            continue;
        }
        if (pc == API_LINK_REQUEST) {
            modem_request();
            jump(pop16());
            continue;
        }
        if (pc == API_LINK_RECEIVE) {
            modem_reply();
            jump(pop16());
            continue;
        }
        if (pc == API_EDIT_LINE) {
            fail("edit_line called");
            break;
        }
        if (pc >= 0x4000 && cmap[pc] != 3) {
            fail("ran %04X, not an instruction", pc);
            break;
        }
        if (cpu.sp < STACK_LOW && cpu.sp > 0x5D00) {
            fail("stack at %04X", cpu.sp);
            break;
        }
        if (cpu.sp < STACK_LOW || cpu.sp > STACK_TOP) {
            fail("stack pointer %04X", cpu.sp);
            break;
        }
        if (tstates - since_key > HANG_T) {
            fail("no key asked for in %llu T-states (hang)", (unsigned long long)HANG_T);
            break;
        }
        trace[trace_n++ % 64] = pc;
        step();
    }
    return -1;
}

static int run_one(const run_t *r)
{
    cur = r;
    rng = r->seed * 0x9E3779B97F4A7C15ull + 1;
    keys_sent = 0;
    in_field = 0;
    reset_machine();
    push16(SENTINEL);
    jump(APP_ADDR);
    run_to(SENTINEL);
    if (failure[0]) {
        if (verbose) {
            printf("FAIL: %s\nlast instructions:", failure);
            for (unsigned i = trace_n > 64 ? trace_n - 64 : 0; i < trace_n; i++)
                printf(" %04X", trace[i % 64]);
            printf("\n");
        }
        return 1;
    }
    log_v("ok: %d keys, %llu T-states\n", keys_sent, (unsigned long long)tstates);
    return 0;
}

/* ---- Inputs --------------------------------------------------------------- */

typedef struct { uint8_t *data; long len; } blob_t;

static blob_t load_blob(const char *path)
{
    blob_t b = { NULL, 0 };
    FILE *f = fopen(path, "rb");
    if (!f)
        die("can't read %s", path);
    fseek(f, 0, SEEK_END);
    b.len = ftell(f);
    fseek(f, 0, SEEK_SET);
    b.data = malloc((size_t)b.len + 1);
    if (fread(b.data, 1, (size_t)b.len, f) != (size_t)b.len)
        die("can't read %s", path);
    fclose(f);
    return b;
}

/* Pieces that 8TML parsers trip over. */
static const char *const pieces[] = {
    "---\n", "8tml: 1\n", "---\n8tml: 1\n", "title: ", "style: ", "case: mixed\n", "case: upper\n",
    "# ", "## ", "### ", "#### ", "* ", "- ", "1. ", "99999. ", "> ", "```\n", ":::form get x\n",
    ":::\n", ":::screen\n", "? text a ", "? select s ", "+ v L\n", "\\\n", "<br>", "<center>",
    "</center>", "<rev>", "<b>", "<i>", "</>", "</b>", "<red>", "<lightgreen>", "<lightgreen",
    "<", ">", "*", "**", "***", "_", "[", "]", "(", ")", "[a](b)", "[](", "](", "[[[[[[[[",
    "&lt;", "&nbsp;", "&#", "&#65;", "&#999999;", "&", ";", "\\*", "\\", "\r", "\r\n", "\t", "\n",
    "\n\n", " ", "                                  ", "`", "\x7F", "\x80", "\xFF", "\x00",
    "http://", "https://a.b/", "../", "./", "#frag", "?q=1", "mailto:x", "%", "@",
    "bg: red\n", "zx.text: blue\n", "h1: yellow reverse center upper\n", "link-sel: \n",
};

static void put(uint8_t *out, long *n, long cap, const void *src, long len)
{
    if (*n + len > cap)
        len = cap - *n;
    if (len > 0) {
        memcpy(out + *n, src, (size_t)len);
        *n += len;
    }
}

/* A page made of random pieces and words, sometimes with a valid header. */
static long gen_page(uint8_t *out, long cap)
{
    long n = 0, target = 1 + rn(rn(4) ? 3000 : 14000);
    static const char *const words[] = { "the", "spectrum", "8tml", "a", "longwordwithoutanyspaces",
        "zx", "!", "...", "x", "12345678901234567890123456789012345" };

    if (rn(4))
        put(out, &n, cap, "---\n8tml: 1\ntitle: Fuzz\n", 24);
    if (rn(3) == 0)
        put(out, &n, cap, "style: s.8ss\n", 13);
    if (rn(4))
        put(out, &n, cap, "---\n", 4);
    while (n < target && n < cap) {
        if (rn(3)) {
            const char *p = pieces[rn(sizeof pieces / sizeof *pieces)];
            put(out, &n, cap, p, p[0] ? (long)strlen(p) : 1);
        } else {
            const char *w = words[rn(sizeof words / sizeof *words)];
            put(out, &n, cap, w, (long)strlen(w));
            put(out, &n, cap, " ", 1);
        }
        if (rn(50) == 0) {                           /* a long run of one thing */
            const char *p = pieces[rn(sizeof pieces / sizeof *pieces)];
            int times = 1 + rn(400);
            for (int i = 0; i < times; i++)
                put(out, &n, cap, p, p[0] ? (long)strlen(p) : 1);
        }
    }
    return n;
}

/* A corpus file, changed a little or a lot. */
static long mutate(const blob_t *in, const blob_t *other, uint8_t *out, long cap)
{
    long n = in->len < cap ? in->len : cap;
    int edits = 1 + rn(rn(4) ? 8 : 64);

    memcpy(out, in->data, (size_t)n);
    for (int e = 0; e < edits; e++) {
        long at = n ? rn((unsigned)n) : 0;
        switch (rn(7)) {
        case 0:                                      /* a random byte */
            if (n)
                out[at] = (uint8_t)rnd();
            break;
        case 1: {                                    /* insert a piece */
            const char *p = pieces[rn(sizeof pieces / sizeof *pieces)];
            long pl = p[0] ? (long)strlen(p) : 1;
            if (n + pl <= cap) {
                memmove(out + at + pl, out + at, (size_t)(n - at));
                memcpy(out + at, p, (size_t)pl);
                n += pl;
            }
            break;
        }
        case 2: {                                    /* delete a stretch */
            long len = rn(64);
            if (at + len > n)
                len = n - at;
            memmove(out + at, out + at + len, (size_t)(n - at - len));
            n -= len;
            break;
        }
        case 3:                                      /* cut the end */
            n = at;
            break;
        case 4: {                                    /* repeat a stretch */
            long len = 1 + rn(200), times = 1 + rn(50);
            if (at + len > n)
                len = n - at;
            for (long t = 0; t < times && n + len <= cap; t++) {
                memmove(out + at + len, out + at, (size_t)(n - at));
                n += len;
            }
            break;
        }
        case 5: {                                    /* splice in another file */
            long from = other->len ? rn((unsigned)other->len) : 0;
            long len = rn(500);
            if (from + len > other->len)
                len = other->len - from;
            if (n + len <= cap) {
                memmove(out + at + len, out + at, (size_t)(n - at));
                memcpy(out + at, other->data + from, (size_t)len);
                n += len;
            }
            break;
        }
        default: {                                   /* a long line */
            long len = 200 + rn(400);
            if (n + len <= cap) {
                memmove(out + at + len, out + at, (size_t)(n - at));
                memset(out + at, "a *[<&\\"[rn(7)], (size_t)len);
                n += len;
            }
            break;
        }
        }
    }
    return n;
}

static long gen_sheet(uint8_t *out, long cap)
{
    static const char *const keys[] = { "text", "bg", "border", "h1", "h2", "h3", "em", "strong",
        "link", "link-sel", "quote", "pre", "rule", "field", "field-sel", "case", "zx.text", "zx.bg",
        "c64.bg", "zx.", ".", "", "charset", "TEXT", "Zx.H1" };
    static const char *const vals[] = { "red", "blue", "lightgreen", "reverse", "center", "upper",
        "mixed", "white reverse center upper", "nocolour", "", "red green blue", "  yellow  ",
        "darkgrey", "#", "BLACK" };
    long n = 0;
    int lines = rn(40);

    for (int i = 0; i < lines; i++) {
        const char *k = keys[rn(sizeof keys / sizeof *keys)];
        const char *v = vals[rn(sizeof vals / sizeof *vals)];
        put(out, &n, cap, k, (long)strlen(k));
        put(out, &n, cap, rn(10) ? ": " : " ", rn(10) ? 2 : 1);
        put(out, &n, cap, v, (long)strlen(v));
        put(out, &n, cap, rn(10) ? "\n" : "\r", 1);
        if (rn(30) == 0)
            for (int j = 0; j < 300; j++)
                put(out, &n, cap, "x", 1);
    }
    return n;
}

static void save_case(const char *dir, unsigned id, const run_t *r)
{
    char path[700];
    snprintf(path, sizeof path, "%s/crash-%u.8tml", dir, id);
    write_file(path, r->page, r->page_len);
    if (r->site) {
        snprintf(path, sizeof path, "%s/crash-%u.site.8ss", dir, id);
        write_file(path, r->site, r->site_len);
    }
    if (r->sheet) {
        snprintf(path, sizeof path, "%s/crash-%u.sheet.8ss", dir, id);
        write_file(path, r->sheet, r->sheet_len);
    }
    snprintf(path, sizeof path, "%s/crash-%u.txt", dir, id);
    {
        FILE *f = fopen(path, "w");
        if (f) {
            fprintf(f, "%s\nseed %llu\n", failure, (unsigned long long)r->seed);
            fclose(f);
        }
    }
}

static int has_ext(const char *name, const char *ext)
{
    size_t n = strlen(name), e = strlen(ext);
    return n > e && !strcmp(name + n - e, ext);
}

static void scan_corpus(const char *dir, blob_t *pages, int *np, blob_t *sheets, int *ns, int depth)
{
    DIR *d = opendir(dir);
    struct dirent *e;
    if (!d)
        die("no corpus %s", dir);
    while ((e = readdir(d)) != NULL) {
        char path[700];
        struct stat st;
        if (e->d_name[0] == '.')
            continue;
        snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
        if (stat(path, &st))
            continue;
        if (S_ISDIR(st.st_mode)) {
            if (depth < 3)
                scan_corpus(path, pages, np, sheets, ns, depth + 1);
        } else if (has_ext(e->d_name, ".8tml") && *np < 512) {
            pages[(*np)++] = load_blob(path);
        } else if (has_ext(e->d_name, ".8ss") && *ns < 512) {
            sheets[(*ns)++] = load_blob(path);
        }
    }
    closedir(d);
}

static int cmd_fuzz(const char *corpus, unsigned long count, uint64_t seed, const char *out_dir)
{
    static blob_t pages[512], sheets[512];
    static uint8_t page[16384], site[4096], sheet[4096];
    int np = 0, ns = 0;
    unsigned fails = 0;
    long page_cap = APP_END - sym_page_buf - 600;    /* room for the url and type */
    clock_t t0 = clock();

    scan_corpus(corpus, pages, &np, sheets, &ns, 0);
    if (!np)
        die("no .8tml files in %s", corpus);
    if (page_cap > (long)sizeof page)
        page_cap = sizeof page;
    for (unsigned long i = 0; i < count; i++) {
        run_t r;
        uint64_t s = seed * 1000003ull + i;
        rng = s * 0x2545F4914F6CDD1Dull + 7;
        r.page = page;
        r.page_len = rn(3) == 0 ? gen_page(page, page_cap)
                   : mutate(&pages[rn(np)], &pages[rn(np)], page, page_cap);
        r.site = rn(3) ? site : NULL;
        r.site_len = r.site ? (ns && rn(2) ? mutate(&sheets[rn(ns)], &sheets[rn(ns)], site, sizeof site)
                                           : gen_sheet(site, sizeof site)) : 0;
        r.sheet = rn(4) ? sheet : NULL;
        r.sheet_len = r.sheet ? (ns && rn(2) ? mutate(&sheets[rn(ns)], &sheets[rn(ns)], sheet, sizeof sheet)
                                             : gen_sheet(sheet, sizeof sheet)) : 0;
        r.seed = s;
        if (run_one(&r)) {
            fails++;
            printf("FAIL %lu (seed %llu): %s\n", i, (unsigned long long)s, failure);
            save_case(out_dir, (unsigned)(s & 0xFFFFFFFF), &r);
            if (fails >= 20)
                break;
        }
        if ((i + 1) % 500 == 0) {
            printf("%lu runs, %u failed, %.0f s\n", i + 1, fails,
                   (double)(clock() - t0) / CLOCKS_PER_SEC);
            fflush(stdout);
        }
    }
    printf("done: %u failed\n", fails);
    return fails ? 1 : 0;
}

/* Every screen of a page as the browser draws it (no keys, no stylesheets):
 * for the comparison with the reference renderer. */
static int cmd_render(const char *page_path, const char *out_path)
{
    blob_t p = load_blob(page_path);
    run_t r = { p.data, p.len, NULL, 0, NULL, 0, 1 };
    FILE *f = fopen(out_path, "wb");
    unsigned screens;

    if (!f)
        die("can't write %s", out_path);
    cur = &r;
    rng = 1;
    reset_machine();
    /* as fetch_url does after a reply: the page in the buffer, then new_page */
    if (p.len > APP_END - sym_page_buf)
        p.len = APP_END - sym_page_buf;
    memcpy(mem + sym_page_buf, p.data, (size_t)p.len);
    {
        uint16_t a;
        a = sym("page_len");      mem[a] = (uint8_t)p.len; mem[a + 1] = (uint8_t)(p.len >> 8);
        a = sym("http_status");   mem[a] = 200; mem[a + 1] = 0;
        a = sym("cur_url");       memcpy(mem + a, "https://test.example/page.8tml", 31);
    }
    push16(SENTINEL);
    jump(sym_new_page);
    if (run_to(SENTINEL))
        die("render: %s", failure);
    screens = mem[sym_screens] | (mem[sym_screens + 1] << 8);
    for (unsigned s = 0; s < screens; s++) {
        mem[sym_page_no] = (uint8_t)s;
        mem[sym_page_no + 1] = (uint8_t)(s >> 8);
        push16(SENTINEL);
        jump(sym_show_page);
        if (run_to(SENTINEL))
            die("render screen %u: %s", s, failure);
        fwrite(mem + 0x4000, 1, 6912, f);
    }
    fclose(f);
    printf("%u screens\n", screens);
    return 0;
}

int main(int argc, char **argv)
{
    const char *args[8];
    const char *site = NULL, *sheet = NULL;
    int na = 0;
    uint64_t seed = 1;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-v"))
            verbose = 1;
        else if (!strcmp(argv[i], "--rom") && i + 1 < argc)
            snprintf(rom_path, sizeof rom_path, "%s", argv[++i]);
        else if (!strcmp(argv[i], "--build") && i + 1 < argc)
            snprintf(build_dir, sizeof build_dir, "%s", argv[++i]);
        else if (!strcmp(argv[i], "--site") && i + 1 < argc)
            site = argv[++i];
        else if (!strcmp(argv[i], "--sheet") && i + 1 < argc)
            sheet = argv[++i];
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc)
            seed = strtoull(argv[++i], NULL, 10);
        else if (na < 8)
            args[na++] = argv[i];
    }
    if (na < 2) {
        fprintf(stderr, "usage: zxfuzz run PAGE [--site F] [--sheet F] [--seed N] [-v]\n"
                        "       zxfuzz fuzz CORPUS COUNT SEED OUT_DIR\n"
                        "       zxfuzz render PAGE OUT.scr\n");
        return 2;
    }
    setup();
    if (!strcmp(args[0], "run")) {
        blob_t p = load_blob(args[1]), s1 = { 0 }, s2 = { 0 };
        run_t r;
        if (site)
            s1 = load_blob(site);
        if (sheet)
            s2 = load_blob(sheet);
        r = (run_t){ p.data, p.len, s1.data, s1.len, s2.data, s2.len, seed };
        if (run_one(&r)) {
            if (!verbose)
                printf("FAIL: %s\n", failure);
            return 1;
        }
        if (!verbose)
            printf("ok: %d keys, %llu T-states\n", keys_sent, (unsigned long long)tstates);
        return 0;
    }
    if (!strcmp(args[0], "fuzz") && na >= 5)
        return cmd_fuzz(args[1], strtoul(args[2], NULL, 10), strtoull(args[3], NULL, 10), args[4]);
    if (!strcmp(args[0], "render") && na >= 3)
        return cmd_render(args[1], args[2]);
    die("unknown command %s", args[0]);
    return 2;
}
