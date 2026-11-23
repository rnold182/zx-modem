r"""Make a code map of a 48K memory image from sjasmplus listings, for zxfuzz.

Usage: python mkmap.py out.map file.lst [file.lst ...]

out.map is 65536 bytes, one per address: 0 = not code (data, buffers, free
memory), 1 = a byte of an instruction, 3 = the first byte of one. zxfuzz
lets the CPU run only from instruction starts (and the ROM), and lets
nothing write to instruction bytes.

Why from the listing: sjasmplus prints each line's address and bytes, and
the source says whether it is an instruction or data (db, dw, ds ...), so
code and the variables between it are told apart exactly.
"""
import re
import sys

# "  123++ A045 AF           main_loop: xor a"  (the + marks include depth)
LINE = re.compile(r'^\s*\d+\+*\s*([0-9A-F]{4}) ((?:[0-9A-F]{2} )+)\s*(.*)$')
DATA = re.compile(r'^(?:[\w.@]+:?\s+)?(?:db|dw|dd|ds|dz|dm|defb|defw|defs|defm|byte|word|block|incbin)\b',
                  re.IGNORECASE)


def mark(cmap, path):
    for line in open(path, encoding='latin-1'):
        m = LINE.match(line)
        if not m:
            continue
        addr = int(m.group(1), 16)
        nbytes = len(m.group(2).split())
        src = m.group(3)
        if re.match(r'(?:[0-9A-F]{2})?\.\.\.', src):  # "00 00 00..." (more bytes): data
            continue
        src = src.split(';')[0].strip()
        if not src or DATA.match(src):
            continue
        # A label alone on a line has no bytes; an instruction has 1-4.
        for i in range(nbytes):
            cmap[(addr + i) & 0xFFFF] = 1
        cmap[addr] = 3


def main(argv):
    if len(argv) < 3:
        raise SystemExit(__doc__)
    cmap = bytearray(65536)
    for path in argv[2:]:
        mark(cmap, path)
    with open(argv[1], 'wb') as f:
        f.write(cmap)
    print(f'{argv[1]}: {sum(1 for b in cmap if b == 3)} instructions')


if __name__ == '__main__':
    main(sys.argv)
