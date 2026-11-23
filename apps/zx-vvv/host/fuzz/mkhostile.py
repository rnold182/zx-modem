"""Write the hostile test pages (testpages/hostile/): inputs a browser must
survive (spec 10, "MUST NOT crash or hang"), from the brief's list and from
what the fuzzer turned up. They are not valid 8TML; zxfuzz runs them.

    python mkhostile.py apps/zx-vvv/testpages/hostile
"""
import os
import sys

H = b'---\n8tml: 1\ntitle: Hostile\n---\n'
BS = b'\\'

PAGES = {
    'empty.8tml': b'',
    'nulbytes.8tml': H + b'text\x00with\x00nuls\n\x00\x00\x00\n# \x00\n[\x00](\x00)\n',
    'high.8tml': H + bytes(range(128, 256)) + b'\n' + bytes(range(0, 32)) + b'\n',
    'hugeline.8tml': H + b'x' * 20000 + b'\n' + b'a ' * 6000 + b'\n',
    'brackets.8tml': H + b'[' * 12000 + b'\n' + b'](' * 3000 + b'\n',
    'tags.8tml': H + b'<' * 4000 + b'\n' + b'<red' * 1000 + b'\n' + b'</' * 2000 + b'\n'
                 + b'&#' * 3000 + b'\n' + b'&' * 4000 + b';\n',
    'stars.8tml': H + b'*' * 9000 + b'\n' + b'** ' * 3000 + b'\n' + BS * 5000 + b'\n',
    'onlycr.8tml': H.replace(b'\n', b'\r') + b'line\rline\r\r# head\r* item\r',
    'header.8tml': b'---\n8tml: 1\ntitle: ' + b'T' * 600 + b'\nstyle: ' + b's' * 400 + b'\n'
                   + b'case: mixed\n' * 300 + b'---\nbody\n',
    'unclosed.8tml': b'---\n8tml: 1\ntitle: never closed\n' + b'key: value\n' * 200,
    'blocks.8tml': H + b'```\n' * 999 + b':::form get\n' + b'? text n ' * 500 + b'\n' + b':::\n' * 999,
    'lists.8tml': H + b''.join(b'%d. item\n' % (99999 - i) for i in range(1500)),
    'links.8tml': H + b'[a](b) ' * 1800 + b'\n',
    'version.8tml': b'---\n8tml: 99999999999999999999\n---\nfrom the future\n',
}


def main(argv):
    out = argv[1] if len(argv) > 1 else os.path.join(os.path.dirname(__file__), '..', '..', 'testpages', 'hostile')
    os.makedirs(out, exist_ok=True)
    for name, data in PAGES.items():
        with open(os.path.join(out, name), 'wb') as f:
            f.write(data)
    print(f'{len(PAGES)} pages in {out}')


if __name__ == '__main__':
    main(sys.argv)
