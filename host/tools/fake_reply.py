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


def response(rtype, data, field45=None, http=0):
    total = len(data) if field45 is None else field45
    hdr = struct.pack('<BBHHBBH', rtype, 1, len(data), total, 0, 1, http)
    out = block(0x90, hdr)
    if data:
        out += block(0x91, data)
    return out


# The firmware's app registry (esp32/main/apps.c): id, kind, available, name.
APPS = [(2, 2, 0, '8TML Browser'), (3, 1, 0, 'Tape Loader (LAN)'), (1, 1, 1, 'Wi-Fi Setup')]


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
