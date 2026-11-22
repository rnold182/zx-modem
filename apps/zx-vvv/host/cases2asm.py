"""url_cases.txt -> an sjasmplus include for the Spectrum self-test
(zx/urltest.asm). Per case: [result code] base 0 ref 0 expected 0; 0xFF ends.

Usage: python cases2asm.py url_cases.txt url_cases.inc
"""
import sys

CODES = {'SAME': 1, 'NOFOLLOW': 2, 'LONG': 3}


def asm_string(s):
    out, run = [], ''
    for ch in s:
        if ch == '"':
            if run:
                out.append(f'"{run}"')
                run = ''
            out.append(str(ord(ch)))
        else:
            run += ch
    if run:
        out.append(f'"{run}"')
    return ','.join(out + ['0'])


def main(src, dst):
    lines = ['; generated from url_cases.txt by cases2asm.py: do not edit', 'url_cases:']
    n = 0
    for line in open(src, encoding='ascii'):
        if line.startswith('#') or '|' not in line:
            continue
        base, ref, want = (x.strip() for x in line.split('|'))
        code = CODES.get(want, 0)
        lines.append(f'\tdb\t{code}')
        for s in (base, ref, '' if code else want):
            while len(s) > 60:                  # sjasmplus: at most 128 bytes per db
                lines.append(f'\tdb\t"{s[:60]}"')
                s = s[60:]
            lines.append(f'\tdb\t{asm_string(s)}')
        n += 1
    lines += ['\tdb\t0xFF', f'URL_CASES\tequ\t{n}', '']
    open(dst, 'w', encoding='ascii', newline='\n').write('\n'.join(lines))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
