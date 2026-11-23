r"""Append canned modem responses to a .tap, for testing Spectrum programs in
an emulator ("offline mode"): the emulator can't answer a request, so the next
blocks on the tape act as the ESP32's reply (docs/link-protocol.md). Append
one response per request the program will make, in order.

Usage: python fake_reply.py in.tap out.tap REPLY [REPLY ...]

REPLY is one of:
  info[:SSID]          system V reply, Wi-Fi connected, clock set, the
                       firmware's app list
  info-noapps          system V reply without an app list (firmware < 0.6)
  info-nowifi          system V reply, no network set, clock not set
  overlay:FILE         system O reply: FILE loaded at 0xA000
  netlist:NAME/RSSI/AUTH[/FLAGS],...   system L or F reply (AUTH 0 = open;
                       FLAGS bit 0 saved, bit 1 connected)
  wifi:A.B.C.D         system J success
  body:STATUS:TEXT     basic F reply (a literal \n in TEXT = new line)
  page:FILE[@URL[@STATUS]]   http G one-reply answer (flag bit 1): the
                       final URL (default https://t8wn.com/index.8tml),
                       type text/8tml, then FILE, with STATUS (default 200)
  httperr:CODE:MESSAGE http G error reply ([code][message])
  refused:STATUS[:TYPE] http G error 6 (a refused type, default text/html),
                       the server's STATUS in the header (firmware 0.8)
  sheet:FILE[@URL]     http G one-reply answer for a stylesheet (200)
  nosheet              http G one-reply answer: no stylesheet there (404)
  tap:FILE             a whole .tap (e.g. a BASIC program to LOAD)
  error:MESSAGE        error reply
"""
import struct
import sys


def block(flag, payload):
    data = bytes([flag]) + payload
    x = 0
    for b in data:
        x ^= b
    return struct.pack('<H', len(data) + 1) + data + bytes([x])


def response(rtype, data, field45=None, http=0, chunk=0xFFFF):
    """One response, chunked like the firmware: one chunk."""
    total = len(data) if field45 is None else field45
    out, off, idx = b'', 0, 0
    while True:
        part = data[off:off + chunk]
        final = off + len(part) >= len(data)
        hdr = struct.pack('<BBHHBBH', rtype, 1 if final else 0, len(part), total, idx, 1, http)
        out += block(0x90, hdr)
        if part:
            out += block(0x91, part)
        off += len(part)
        idx += 1
        if final:
            return out


# The firmware's app registry (esp32/main/apps.c): id, kind, available, name.
APPS = [(2, 1, 1, 'zx-vvv'), (3, 1, 0, 'Tape Loader (LAN)'), (1, 1, 1, 'Wi-Fi Setup')]


def info(ssid, wifi=2, clock=True, apps=True):
    d = bytes([0, 6, 1, wifi]) + (bytes([192, 168, 1, 42]) if wifi == 2 else bytes(4))
    d += bytes([(-58) & 0xFF if wifi == 2 else 0, 1 if clock else 0])
    d += struct.pack('<H', 2026) + bytes([11, 18, 21, 42, 5, 3])
    s = ssid.encode('ascii')[:32]
    d += bytes([len(s)]) + s
    if apps:
        d += bytes([len(APPS)])
        for app_id, kind, avail, name in APPS:
            d += bytes([app_id, kind, avail, len(name)]) + name.encode('ascii')
    return d


def reply(spec):
    kind, _, arg = spec.partition(':')
    if kind == 'info':
        return response(7, info(arg or 'HomeNet'))
    if kind == 'info-noapps':
        return response(7, info(arg or 'HomeNet', apps=False))
    if kind == 'info-nowifi':
        return response(7, info('', wifi=0, clock=False))
    if kind == 'overlay':
        with open(arg, 'rb') as f:
            return response(6, f.read(), field45=0xA000)
    if kind == 'netlist':
        d = b''
        for item in arg.split(','):
            name, rssi, auth, *flags = item.split('/')
            n = name.encode('ascii')[:32]
            d += bytes([int(rssi) & 0xFF, int(auth), int(flags[0]) if flags else 0, len(n)]) + n
        return response(4, d)
    if kind == 'wifi':
        return response(5, bytes(int(x) for x in arg.split('.')))
    if kind == 'body':
        status, _, text = arg.partition(':')
        return response(0, text.replace('\\n', '\n').encode('ascii'), http=int(status))
    if kind == 'page':
        # FILE@URL@STATUS: the URL may hold '@' itself (t8wn.com/@name/)
        name, _, rest = arg.partition('@')
        url, status = rest, None
        head, sep, tail = rest.rpartition('@')
        if sep and tail.isdigit():
            url, status = head, tail
        url = url or 'https://t8wn.com/index.8tml'
        with open(name, 'rb') as f:
            body = f.read()
        # one reply (http G flag bit 1, as zx-vvv asks): url 0 type 0 body
        return response(0, url.encode('ascii') + b'\0text/8tml\0' + body, http=int(status or 200))
    if kind == 'sheet':                 # a stylesheet: one reply, 200, text/plain
        name, _, url = arg.partition('@')
        with open(name, 'rb') as f:
            sheet = f.read()
        return response(0, (url or 'https://test.example/site.8ss').encode('ascii') + b'\0text/plain\0' + sheet, http=200)
    if kind == 'nosheet':               # no stylesheet there: one reply, 404
        return response(0, b'https://test.example/site.8ss\0text/plain\0Not found\n', http=404)
    if kind == 'httperr':
        code, _, msg = arg.partition(':')
        return response(1, bytes([int(code)]) + msg.encode('ascii'))
    if kind == 'refused':
        status, _, ctype = arg.partition(':')
        return response(1, bytes([6]) + (ctype or 'text/html').encode('ascii'), http=int(status))
    if kind == 'tap':
        with open(arg, 'rb') as f:
            return f.read()
    if kind == 'error':
        return response(1, arg.encode('ascii'))
    raise SystemExit(f'unknown reply: {spec}')


def main(argv):
    if len(argv) < 4:
        raise SystemExit(__doc__)
    with open(argv[1], 'rb') as f:
        tap = f.read()
    for spec in argv[3:]:
        tap += reply(spec)
    with open(argv[2], 'wb') as f:
        f.write(tap)


if __name__ == '__main__':
    main(sys.argv)
