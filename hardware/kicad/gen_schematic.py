"""Generate the rev A schematic (zx-modem.kicad_sch) from one parts + nets table.

Usage (from the repo root):  python -I hardware/kicad/gen_schematic.py

Why a generator: every connection is written down once, in PARTS below, and the
schematic, the ERC run and the netlist cross-check (check_netlist.py) all come
from it. The drawing is laid out per functional block (BLOCKS): parts sit on a
2.54 mm grid, nets are wired with straight or single-bend wires where that stays
clear of other parts and nets, power nets get power symbols, and nets that leave
a block get global labels. check_netlist.py proves the result matches PARTS.

Symbols and footprints come from KiCad 10's own libraries; their pin numbers
match the footprint pad names (checked: module 1-41, USB-C A1..B12/SH,
jack T/S/R1/R2, SOT-23-5 1-5).
"""
import math, os, re, uuid

KICAD = os.environ.get('KICAD_SHARE', 'C:/Program Files/KiCad/10.0/share/kicad')
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'zx-modem.kicad_sch')
PROJECT = 'zx-modem'
ROOT_UUID = '5a1e7c3d-0b5e-4d1e-9a6f-7a3e2c1d0001'   # fixed, so regenerating gives a stable diff

def uid(seed):                                       # deterministic UUIDs, same reason
    return str(uuid.uuid5(uuid.UUID(ROOT_UUID), seed))

R0805, C0805 = 'Resistor_SMD:R_0805_2012Metric', 'Capacitor_SMD:C_0805_2012Metric'
JACK = 'zx-modem:PJ-307'

# ref: (lib_id, value, footprint, LCSC, {pin: net}, (gx, gy, rot[, 'mx']) schematic placement, flags)
# Placement is in grid units of 2.54 mm; rot is in degrees; 'mx' mirrors top-bottom.
# Rev B carrier board: an ESP32-S3 SuperMini dev board (USB-C, 3.3 V, BOOT/RESET on board) is
# soldered on. flags: 'hand' = you solder it (not in the JLCPCB BOM/CPL), 'mpn' = what to buy.
# Net names follow hardware/DESIGN.md. Pins not listed get a no-connect.
PARTS = {
    # --- ESP32-S3 SuperMini and the PLAY button ---------------------------------------
    'U1': ('zx-modem:ESP32-S3-SuperMini', 'ESP32-S3 SuperMini', 'zx-modem:ESP32-S3-SuperMini', '',
           {'6': 'RX', '7': 'ADC_TAP', '8': 'TX_GPIO', '9': 'PLAY', '11': 'GND', '12': '3V3'},
           (20, 20, 0), {'hand': True, 'mpn': 'ESP32-S3 SuperMini (pinout per espboards.dev)'}),
    'R18': ('Device:R', '10k', R0805, 'C17414', {'1': '3V3', '2': 'PLAY'}, (8, 28.5, 0), {}),
    'C12': ('Device:C', '100n', C0805, 'C49678', {'1': 'PLAY', '2': 'GND'}, (12, 31.5, 0), {}),
    'R19': ('Device:R', '1k', R0805, 'C17513', {'1': 'PLAY', '2': 'BTN_PLAY_SW'}, (17.5, 30, 90), {}),
    'SW3': ('Switch:SW_Push', 'PLAY', 'Button_Switch_SMD:SW_Push_1P1T_XKB_TS-1187A', 'C318884',
            {'1': 'BTN_PLAY_SW', '2': 'GND'}, (28, 30, 0), {}),
    # --- TX to EAR -------------------------------------------------------------------
    'D2': ('Diode:BAT54S', 'BAT54S', 'Package_TO_SOT_SMD:SOT-23', 'C47546',
           {'1': 'GND', '2': '3V3', '3': 'TX_GPIO'}, (49, 16, 0), {}),
    'R5': ('Device:R', '220', R0805, 'C17557', {'1': 'TX_GPIO', '2': 'EAR_OUT'}, (57.5, 18, 90), {}),
    'R6': ('Device:R', 'DNP', R0805, '', {'1': 'EAR_OUT', '2': 'GND'}, (63, 19.5, 0), {'dnp': True}),
    # PJ-307 jacks, pinout measured on the local jacks: 1 sleeve, 2 tip, 5 ring (right channel);
    # 3 and 4 are switch contacts that carry nothing with a plug in, so they stay unconnected
    # (that also keeps the signal from being shorted through a switch when no plug is in).
    # Tip = signal; sleeve and ring = GND (a mono plug's sleeve touches the ring contact anyway).
    # JLCPCB fits them (HOOYA PJ-307, C2939173, wave soldered); our footprint is drawn from theirs.
    'J2': ('zx-modem:PJ-307', 'EAR', JACK, 'C2939173',
           {'2': 'EAR_OUT', '1': 'GND', '5': 'GND'}, (69, 19, 180), {}),
    # --- RX from MIC: input R, 2-pole high-pass, clamp, comparator -------------------
    'J3': ('zx-modem:PJ-307', 'MIC', JACK, 'C2939173',
           {'2': 'MIC_IN', '1': 'GND', '5': 'GND'}, (6, 56, 0, 'mx'), {}),
    'R20': ('Device:R', '1k', R0805, 'C17513', {'1': 'MIC_IN', '2': 'MIC_R'}, (13.5, 55, 90), {}),
    'C7': ('Device:C', '10n', C0805, 'C1710', {'1': 'MIC_R', '2': 'HP_A'}, (19.5, 55, 90), {}),
    'R7': ('Device:R', '68k', R0805, 'C17801', {'1': 'HP_A', '2': 'VBIAS'}, (24, 56.5, 0), {}),
    'C8': ('Device:C', '1n', C0805, 'C51210', {'1': 'HP_A', '2': 'HP_B'}, (28.5, 55, 90), {}),
    'R8': ('Device:R', '680k', R0805, 'C17797', {'1': 'HP_B', '2': 'VBIAS'}, (33, 56.5, 0), {}),
    'D1': ('Diode:BAT54S', 'BAT54S', 'Package_TO_SOT_SMD:SOT-23', 'C47546',
           {'1': 'GND', '2': '3V3', '3': 'HP_B'}, (43, 57, 0, 'mx'), {}),
    'R17': ('Device:R', '10k', R0805, 'C17414', {'1': 'HP_B', '2': 'CMP_IN'}, (53.5, 55, 90), {}),
    'R14': ('Device:R', '10k', R0805, 'C17414', {'1': 'HP_B', '2': 'ADC_TAP'}, (50, 56.5, 0), {}),
    'C11': ('Device:C', '100p', C0805, 'C1790', {'1': 'ADC_TAP', '2': 'GND'}, (50, 60, 0), {}),
    'U4': ('Comparator:TLV7031DBV', 'TLV7031', 'Package_TO_SOT_SMD:SOT-23-5', 'C2869832',
           {'1': 'RX', '2': 'GND', '3': 'CMP_REF', '4': 'CMP_IN', '5': '3V3'}, (64, 54, 0), {}),
    'C10': ('Device:C', '100n', C0805, 'C49678', {'1': '3V3', '2': 'GND'}, (67, 45.5, 0), {}),
    'R12': ('Device:R', '470k', R0805, 'C17709', {'1': 'RX', '2': 'CMP_REF'}, (61, 49.5, 0), {}),
    # hysteresis: CMP_REF sits 1.5k above VBIAS; with R12 470k that's 3.3 V x 1.5/471.5 = 10.5 mV
    'R11': ('Device:R', '1.5k', R0805, 'C4310', {'1': 'VBIAS', '2': 'CMP_REF'}, (56, 51.5, 0), {'text_left': True}),
    'R9': ('Device:R', '10k', R0805, 'C17414', {'1': '3V3', '2': 'VBIAS'}, (26, 59.5, 180), {}),
    'R10': ('Device:R', '10k', R0805, 'C17414', {'1': 'VBIAS', '2': 'GND'}, (29, 59.5, 0), {}),
    'C9': ('Device:C', '10u', C0805, 'C15850', {'1': 'VBIAS', '2': 'GND'}, (35, 59.5, 0), {}),
    # --- power flag: GND comes from the SuperMini's GND pin ----------------------------
    '#FLG02': ('power:PWR_FLAG', 'PWR_FLAG', '', '', {'1': 'GND'}, (34, 30, 0), {'power': True}),
}

# ---------------------------------------------------------------------------------------
def find_block(text, head):
    """Return the balanced (...) block that starts at the first occurrence of head."""
    i = text.find(head)
    if i < 0: raise KeyError(head)
    d = 0; j = i; instr = False                       # strings may contain parentheses
    while True:
        c = text[j]
        if instr:
            if c == '\\': j += 1
            elif c == '"': instr = False
        elif c == '"': instr = True
        elif c == '(': d += 1
        elif c == ')':
            d -= 1
            if d == 0: return text[i:j + 1]
        j += 1

_libcache = {}
def lib_text(lib):
    if lib not in _libcache:
        path = os.path.join(HERE, 'zx-modem.kicad_sym') if lib == 'zx-modem' else f'{KICAD}/symbols/{lib}.kicad_sym'
        with open(path, encoding='utf-8') as f:
            _libcache[lib] = f.read()
    return _libcache[lib]

def lib_symbol(lib_id):
    """Flattened library symbol, renamed to lib_id, ready for the lib_symbols section."""
    lib, name = lib_id.split(':')
    text = lib_text(lib)
    blk = find_block(text, f'(symbol "{name}"')
    m = re.search(r'\(extends "([^"]*)"\)', blk)
    if m:                                             # derived symbol: parent body + own properties
        parent = m.group(1)
        pblk = find_block(text, f'(symbol "{parent}"')
        for prop in re.findall(r'\(property "([^"]*)"', blk):
            child_p = find_block(blk, f'(property "{prop}"')
            try:
                parent_p = find_block(pblk, f'(property "{prop}"')
                pblk = pblk.replace(parent_p, child_p, 1)
            except KeyError:
                pblk = pblk.replace('(property "Reference"', child_p + '\n(property "Reference"', 1)
        blk = pblk.replace(f'(symbol "{parent}_', f'(symbol "{name}_')
        blk = blk.replace(f'(symbol "{parent}"', f'(symbol "{name}"', 1)
    return blk.replace(f'(symbol "{name}"', f'(symbol "{lib_id}"', 1)

def pins_of(symblk):
    """[(number, x, y, angle)] in symbol coordinates (y up)."""
    out = []
    for m in re.finditer(r'\(pin \w+ \w+\s*\(at ([-\d.]+) ([-\d.]+) (\d+)\)', symblk):
        pblk = find_block(symblk[m.start():], '(pin ')
        num = re.search(r'\(number "([^"]*)"', pblk).group(1)
        out.append((num, float(m.group(1)), float(m.group(2)), int(m.group(3))))
    return out

def fmt(v):
    return f'{round(v, 4):g}'

def font(hide=False, justify=None):
    j = f' (justify {justify})' if justify else ''
    h = ' (hide yes)' if hide else ''
    return f'(effects (font (size 1.27 1.27)){j}{h})'

def prop(name, value, x, y, hide=False, justify=None, angle=0):
    return f'(property "{name}" "{value}" (at {fmt(x)} {fmt(y)} {angle}) {font(hide, justify)})'

# Functional blocks: frame (gx0, gy0, gx1, gy1) in grid units, title, members.
# Wires are only drawn inside a block; nets that leave a block get global labels.
BLOCKS = {
    'mcu': ((2, 6, 40, 37), 'ESP32-S3 SuperMini (hand-soldered) and PLAY button',
            ['U1', 'R18', 'C12', 'R19', 'SW3', '#FLG02']),
    'tx': ((43, 6, 80, 37), 'TX: ESP32 to Spectrum EAR', ['D2', 'R5', 'R6', 'J2']),
    'rx': ((2, 40, 72, 64.5), 'RX: Spectrum MIC to ESP32 (234 Hz 2-pole high-pass, clamp, comparator)',
           ['J3', 'R20', 'C7', 'R7', 'C8', 'R8', 'D1', 'R17', 'R14', 'C11', 'U4', 'C10', 'R12',
            'R9', 'R10', 'C9', 'R11']),
}
G = 2.54                                              # grid unit
POWER = {'GND': 'power:GND', '3V3': 'power:+3V3'}
LMAX = 12 * G                                         # longest wire drawn; longer nets use labels
EPS = 0.01

def tf(px, py, rot, mx):
    """Symbol coordinates (mm, y up) to a sheet offset (mm, y down): mirror, then rotate CCW."""
    u, v = px, -py
    if mx: v = -v
    a = math.radians(rot); c, s_ = round(math.cos(a)), round(math.sin(a))
    return u * c + v * s_, -u * s_ + v * c

def body_box(symblk, x, y, rot, mx):
    """Bounding box of a symbol's drawing (not its pins or texts) on the sheet."""
    pts = []
    for unit in re.finditer(r'\(symbol "[^"]*_\d+_\d+"', symblk):
        ublk = find_block(symblk[unit.start():], '(symbol ')
        ublk = re.sub(r'\(pin \w+ \w+.*?\(number "[^"]*"(?:[^()]|\([^()]*\))*\)\s*\)', '', ublk, flags=re.S)
        pts += [(float(a), float(b)) for a, b in
                re.findall(r'\((?:xy|start|end|center|mid) ([-\d.]+) ([-\d.]+)\)', ublk)]
    if not pts: return None
    sx = [x + tf(a, b, rot, mx)[0] for a, b in pts]; sy = [y + tf(a, b, rot, mx)[1] for a, b in pts]
    return min(sx), min(sy), max(sx), max(sy)

def on_seg(p, a, b):
    """True if point p lies on the axis-parallel segment a-b (ends included)."""
    if abs(a[0] - b[0]) < EPS:
        return abs(p[0] - a[0]) < EPS and min(a[1], b[1]) - EPS <= p[1] <= max(a[1], b[1]) + EPS
    return abs(p[1] - a[1]) < EPS and min(a[0], b[0]) - EPS <= p[0] <= max(a[0], b[0]) + EPS

def seg_hits_box(a, b, box, shrink=0.1):
    x0, y0, x1, y1 = box[0] + shrink, box[1] + shrink, box[2] - shrink, box[3] - shrink
    if x0 >= x1 or y0 >= y1: return False
    return not (max(a[0], b[0]) <= x0 or min(a[0], b[0]) >= x1 or max(a[1], b[1]) <= y0 or min(a[1], b[1]) >= y1)

def segs_touch(a, b, c, d):
    """Axis-parallel segments a-b and c-d share at least one point."""
    if max(min(a[0], b[0]), min(c[0], d[0])) > min(max(a[0], b[0]), max(c[0], d[0])) + EPS: return False
    return max(min(a[1], b[1]), min(c[1], d[1])) <= min(max(a[1], b[1]), max(c[1], d[1])) + EPS

def colinear_overlap(a, b, c, d):
    h1, h2 = abs(a[1] - b[1]) < EPS, abs(c[1] - d[1]) < EPS
    if h1 != h2: return False
    if h1:
        if abs(a[1] - c[1]) > EPS: return False
        return min(max(a[0], b[0]), max(c[0], d[0])) - max(min(a[0], b[0]), min(c[0], d[0])) > EPS
    if abs(a[0] - c[0]) > EPS: return False
    return min(max(a[1], b[1]), max(c[1], d[1])) - max(min(a[1], b[1]), min(c[1], d[1])) > EPS

def direction(e, o):
    return (0 if abs(o[0] - e[0]) < EPS else (1 if o[0] > e[0] else -1),
            0 if abs(o[1] - e[1]) < EPS else (1 if o[1] > e[1] else -1))

def main():
    libs, parts = {}, {}
    block_of = {r: b for b, (_, _, members) in BLOCKS.items() for r in members}
    assert set(block_of) == set(PARTS), set(PARTS) ^ set(block_of)

    # 1. place every symbol; collect pins (sheet position, outward direction, net)
    pins = []
    for ref, (lib_id, value, fp, lcsc, conns, place, flags) in PARTS.items():
        gx, gy, rot = place[:3]; mx = len(place) > 3
        x, y = gx * G, gy * G
        if lib_id not in libs: libs[lib_id] = lib_symbol(lib_id)
        sp = pins_of(libs[lib_id])
        missing = set(conns) - {p[0] for p in sp}
        assert not missing, f'{ref}: no such pin(s) {missing}'
        parts[ref] = dict(lib_id=lib_id, x=x, y=y, rot=rot, mx=mx, box=body_box(libs[lib_id], x, y, rot, mx),
                          pins=sp, flags=flags, value=value, fp=fp, lcsc=lcsc)
        seen = {}
        for num, px, py, ang in sp:
            ox, oy = tf(px, py, rot, mx)
            cx, cy = round(x + ox, 3), round(y + oy, 3)
            dx, dy = tf(math.cos(math.radians(ang)), math.sin(math.radians(ang)), rot, mx)   # toward the body
            pin = dict(ref=ref, num=num, p=(cx, cy), out=(-round(dx), -round(dy)),
                       inner=(round(cx + dx * 2.54, 3), round(cy + dy * 2.54, 3)), net=conns.get(num))
            if (cx, cy) in seen:                      # stacked pins share one connection point
                if pin['net'] and not seen[(cx, cy)]['net']: seen[(cx, cy)]['net'] = pin['net']
                continue
            seen[(cx, cy)] = pin; pins.append(pin)

    boxes = [d['box'] for d in parts.values() if d['box']]
    wires = []                                        # (a, b, net)

    def clear(a, b, net):
        """Can a wire of `net` run from a to b without touching anything of another net?"""
        if any(seg_hits_box(a, b, bx) for bx in boxes): return False
        for q in pins:
            if q['net'] != net and (on_seg(q['p'], a, b) or segs_touch(a, b, q['p'], q['inner'])): return False
        for c, d, n in wires:
            if n != net and segs_touch(a, b, c, d): return False
            if n == net and colinear_overlap(a, b, c, d): return False
        return True

    # 2. wire each net inside each block: shortest clear straight or single-bend links (Kruskal)
    nets = {}
    for q in pins:
        if q['net']: nets.setdefault(q['net'], []).append(q)
    for net, qs in nets.items():
        parent = list(range(len(qs)))
        def find(i):
            while parent[i] != i:
                parent[i] = parent[parent[i]]; i = parent[i]
            return i
        if True:                                      # ground: only pins of one part (jack R + S)
            cands = []
            for i in range(len(qs)):
                for j in range(i + 1, len(qs)):
                    a, b = qs[i]['p'], qs[j]['p']
                    if block_of[qs[i]['ref']] != block_of[qs[j]['ref']]: continue
                    if net == 'GND' and qs[i]['ref'] != qs[j]['ref']: continue
                    dx, dy = abs(a[0] - b[0]), abs(a[1] - b[1])
                    if dx + dy > LMAX or (dx < EPS and dy < EPS): continue
                    if dx < EPS or dy < EPS: cands.append((dx + dy, i, j, [a, b]))
                    else:
                        cands.append((dx + dy + 0.5, i, j, [a, (b[0], a[1]), b]))
                        cands.append((dx + dy + 0.6, i, j, [a, (a[0], b[1]), b]))
            for _, i, j, path in sorted(cands, key=lambda c: c[0]):
                if find(i) == find(j): continue
                segs = list(zip(path, path[1:]))
                if all(clear(a, b, net) for a, b in segs):
                    for a, b in segs: wires.append((a, b, net))
                    parent[find(i)] = find(j)
        for k, q in enumerate(qs): q['grp'] = find(k)

    def busy(q):
        """Is the pin's outward direction already taken by a wire?"""
        for a, b, n in wires:
            for e, o in ((a, b), (b, a)):
                if abs(e[0] - q['p'][0]) < EPS and abs(e[1] - q['p'][1]) < EPS and direction(e, o) == q['out']:
                    return True
        return False

    def crowded(q):
        """Another pin of the same part sits just below this one (a ground symbol hung below would hit it)."""
        return any(o is not q and o['ref'] == q['ref'] and abs(o['p'][0] - q['p'][0]) < EPS
                   and 0 < o['p'][1] - q['p'][1] <= 2 * G + EPS for o in pins)

    def tag_wire(net):
        """Put the net's label on a short stub from the middle of its longest wire."""
        segs = sorted((s for s in wires if s[2] == net),
                      key=lambda s: -(abs(s[0][0] - s[1][0]) + abs(s[0][1] - s[1][1])))
        for a, b, _ in segs:
            if abs(a[0] - b[0]) + abs(a[1] - b[1]) < 2 * G - EPS: continue
            m = (round(round((a[0] + b[0]) / 2 / 1.27) * 1.27, 3), round(round((a[1] + b[1]) / 2 / 1.27) * 1.27, 3))
            if m in (a, b) or not on_seg(m, a, b): continue
            dirs = [(0, -1), (0, 1)] if abs(a[1] - b[1]) < EPS else [(1, 0), (-1, 0)]
            for d in dirs:
                e = (round(m[0] + d[0] * G, 3), round(m[1] + d[1] * G, 3))
                ln = len(net) * 1.1 + 2.5             # label length along d
                tip = (e[0] + d[0] * ln, e[1] + d[1] * ln)
                lb = (min(e[0], tip[0]) - 0.8, min(e[1], tip[1]) - 0.8, max(e[0], tip[0]) + 0.8, max(e[1], tip[1]) + 0.8)
                if any(not (lb[2] <= bx[0] or lb[0] >= bx[2] or lb[3] <= bx[1] or lb[1] >= bx[3]) for bx in boxes):
                    continue
                if any(n2 != net and not (max(c[0], d2[0]) < lb[0] or min(c[0], d2[0]) > lb[2] or
                                          max(c[1], d2[1]) < lb[1] or min(c[1], d2[1]) > lb[3])
                       for c, d2, n2 in wires):
                    continue                          # the label would cross another net's wire
                fr = BLOCKS[block_of[[q for q in pins if q['net'] == net][0]['ref']]][0]
                if lb[0] < fr[0] * G or lb[2] > fr[2] * G or lb[1] < fr[1] * G or lb[3] > fr[3] * G:
                    continue                          # keep the label inside its block
                if clear(m, e, net):
                    wires.append((m, e, net)); label(net, e, d); return True
        return False

    items = []
    counter = [0]
    def stub(q, start=None, d=None, length=G):
        s0, d = start or q['p'], d or q['out']
        e = (round(s0[0] + d[0] * length, 3), round(s0[1] + d[1] * length, 3))
        if not clear(s0, e, q['net']): return None
        wires.append((s0, e, q['net'])); return e

    def power_symbol(net, at, d):
        counter[0] += 1
        lib_id = POWER[net]
        if lib_id not in libs: libs[lib_id] = lib_symbol(lib_id)
        # GND hangs down at 0 degrees; 3V3 and VBUS point up. Turn them to point along d.
        if net == 'GND': rot = {(0, 1): 0, (1, 0): 90, (0, -1): 180, (-1, 0): 270}[d]
        else: rot = {(0, -1): 0, (-1, 0): 90, (0, 1): 180, (1, 0): 270}[d]
        ref = f'#PWR{counter[0]:03d}'
        tx, ty = at[0] + d[0] * 3.6, at[1] + d[1] * 3.6 + (1.0 if d[1] == 0 else 0)
        items.append(
            f'(symbol (lib_id "{lib_id}") (at {fmt(at[0])} {fmt(at[1])} {rot}) (unit 1) (exclude_from_sim no)'
            f' (in_bom no) (on_board yes) (dnp no) (uuid "{uid(ref)}")'
            f' {prop("Reference", ref, at[0], at[1], hide=True)}'
            f' (property "Value" "{net}" (at {fmt(tx)} {fmt(ty)} {90 if rot in (90, 270) else 0}) {font()})'
            f' {prop("Footprint", "", at[0], at[1], hide=True)} {prop("Datasheet", "", at[0], at[1], hide=True)}'
            f' {prop("Description", "", at[0], at[1], hide=True)} (pin "1" (uuid "{uid(ref + "/pin")}"))'
            f' (instances (project "{PROJECT}" (path "/{ROOT_UUID}" (reference "{ref}") (unit 1)))))')

    def label(net, at, d):
        ang = {(1, 0): 0, (0, -1): 90, (-1, 0): 180, (0, 1): 270}[d]
        just = 'left' if ang in (0, 90) else 'right'
        counter[0] += 1
        items.append(f'(global_label "{net}" (shape passive) (at {fmt(at[0])} {fmt(at[1])} {ang})'
                     f' {font(justify=just)} (uuid "{uid("lbl" + str(counter[0]))}")'
                     f' (property "Intersheetrefs" "${{INTERSHEET_REFS}}" (at {fmt(at[0])} {fmt(at[1])} 0)'
                     f' {font(hide=True)}))')

    # 3. power symbols and labels: one per wired group (GND: one per pin)
    for net, qs in nets.items():
        groups = {}
        for q in qs: groups.setdefault(q['grp'], []).append(q)
        # A fully wired signal net still gets one label: it names the net (HP_A, EN...) for the
        # reader, and KiCad would otherwise invent a name the board doesn't use.
        for g in groups.values():
            done = False
            if net == 'GND':                          # sideways ground pin: out, then down
                for q in g:
                    if q['out'] in ((1, 0), (-1, 0)) and not busy(q) and not crowded(q):
                        e = stub(q)
                        e2 = e and stub(q, start=e, d=(0, 1))
                        if e2: power_symbol(net, e2, (0, 1)); done = True; break
            if done: continue
            for q in sorted(g, key=lambda q: (busy(q), q['ref'].startswith('#'))):
                if not busy(q):
                    e = stub(q)
                    if e:
                        (power_symbol if net in POWER else label)(net, e, q['out']); break
                if net == 'GND': continue
            else:
                if net not in POWER and len(groups) == 1 and tag_wire(net):
                    continue                          # fully wired, no free pin: name it on its longest wire
                q = g[0]                              # last resort: right on the first pin
                d = q['out'] if not busy(q) else (1, 0)
                (power_symbol if net in POWER else label)(net, q['p'], d)
            if net == 'GND': pass

    # 4. no-connect flags, T-splits and junctions
    for q in pins:
        if not q['net']:
            items.append(f'(no_connect (at {fmt(q["p"][0])} {fmt(q["p"][1])}) (uuid "{uid("nc" + q["ref"] + q["num"])}"))')
    ends = {}
    for a, b, n in wires:
        for e in (a, b): ends[e] = ends.get(e, 0) + 1
    split = []
    for a, b, n in wires:                             # a wire end on the middle of a same-net wire: split it
        mids = sorted({e for c, d, n2 in wires if n2 == n for e in (c, d) if on_seg(e, a, b) and e not in (a, b)},
                      key=lambda e: (e[0] - a[0]) ** 2 + (e[1] - a[1]) ** 2)
        pts = [a] + mids + [b]
        for c, d in zip(pts, pts[1:]): split.append((c, d, n))
        for e in mids: ends[e] = ends.get(e, 0) + 2
    for q in pins:
        if q['p'] in ends: ends[q['p']] += 1
    for i, (a, b, n) in enumerate(split):
        items.append(f'(wire (pts (xy {fmt(a[0])} {fmt(a[1])}) (xy {fmt(b[0])} {fmt(b[1])}))'
                     f' (stroke (width 0) (type default)) (uuid "{uid(f"w{i}")}"))')
    for e, k in ends.items():
        if k >= 3:
            items.append(f'(junction (at {fmt(e[0])} {fmt(e[1])}) (diameter 0) (color 0 0 0 0) (uuid "{uid("j" + str(e))}"))')

    # 5. the symbols, with reference and value where a reader expects them
    for ref, d in parts.items():
        x, y, flags = d['x'], d['y'], d['flags']
        is_pwr = flags.get('power', False)
        bx = d['box'] or (x - 2, y - 2, x + 2, y + 2)
        two_pin = d['lib_id'] in ('Device:R', 'Device:C', 'Device:LED')
        mine = [q['p'] for q in pins if q['ref'] == ref]
        vertical = two_pin and abs(mine[0][0] - mine[-1][0]) < EPS
        tang = 90 if d['rot'] in (90, 270) else 0     # field angles turn with the symbol: undo it
        if two_pin and vertical and flags.get('text_left'):
            rp, vp, just = (bx[0] - 0.8, y - 0.4), (bx[0] - 0.8, y + 1.8), 'right'
        elif two_pin and vertical:
            rp, vp, just = (bx[2] + 0.8, y - 0.4), (bx[2] + 0.8, y + 1.8), 'left'
        elif two_pin:
            rp, vp, just = (x, bx[1] - 1.0), (x, bx[3] + 2.2), None
        else:
            outs = {q['out'] for q in pins if q['ref'] == ref and q['net'] is not None or q['ref'] == ref}
            cx = (bx[0] + bx[2]) / 2
            if (0, 1) in outs and (0, -1) in outs:     # pins above and below: text on the right
                rp, vp, just = (bx[2] + 2.5, bx[1] - 0.6), (bx[2] + 2.5, bx[1] - 2.4), 'left'
            elif (0, 1) in outs:                       # a pin hangs below: both texts above
                rp, vp, just = (cx, bx[1] - 3.4), (cx, bx[1] - 1.2), None
            elif (0, -1) in outs:                      # a pin sticks up: both texts below
                rp, vp, just = (cx, bx[3] + 2.4), (cx, bx[3] + 4.6), None
            else:
                rp, vp, just = (cx, bx[1] - 1.2), (cx, bx[3] + 2.4), None
        if d['rot'] == 180 and just:                  # KiCad mirrors the justification of a 180-degree symbol
            just = {'left': 'right', 'right': 'left'}[just]
        props = [prop('Reference', ref, *rp, hide=is_pwr, justify=just, angle=tang),
                 prop('Value', d['value'], *vp, hide=is_pwr, justify=just, angle=tang),
                 prop('Footprint', d['fp'], x, y, hide=True), prop('Datasheet', '', x, y, hide=True),
                 prop('Description', '', x, y, hide=True)]
        if not is_pwr: props.append(prop('LCSC', d['lcsc'], x, y, hide=True))
        nums = sorted({p[0] for p in d['pins']})
        pin_uuids = ' '.join(f'(pin "{n}" (uuid "{uid(ref + "/pin/" + n)}"))' for n in nums)
        in_bom = 'no' if (is_pwr or flags.get('dnp') or not flags.get('in_bom', True)) else 'yes'
        mirror = ' (mirror x)' if d['mx'] else ''
        items.append(
            f'(symbol (lib_id "{d["lib_id"]}") (at {fmt(x)} {fmt(y)} {d["rot"]}){mirror} (unit 1)'
            f' (exclude_from_sim no) (in_bom {in_bom}) (on_board {"no" if is_pwr else "yes"})'
            f' (dnp {"yes" if flags.get("dnp") else "no"}) (uuid "{uid(ref)}")\n  '
            + '\n  '.join(props) + f'\n  {pin_uuids}\n'
            f'  (instances (project "{PROJECT}" (path "/{ROOT_UUID}" (reference "{ref}") (unit 1)))))')

    # 6. block frames and titles
    for name, ((x0, y0, x1, y1), title, _) in BLOCKS.items():
        items.append(f'(rectangle (start {fmt(x0 * G)} {fmt(y0 * G)}) (end {fmt(x1 * G)} {fmt(y1 * G)})'
                     f' (stroke (width 0.254) (type dash)) (fill (type none)) (uuid "{uid("frame" + name)}"))')
        items.append(f'(text "{title}" (exclude_from_sim no) (at {fmt(x0 * G + 2)} {fmt(y0 * G + 4)} 0)'
                     f' (effects (font (size 2 2) (bold yes)) (justify left bottom)) (uuid "{uid("title" + name)}"))')
    items.append('(text "Generated by hardware/kicad/gen_schematic.py from its PARTS table - edit there, not here."'
                 f' (exclude_from_sim no) (at {fmt(2 * G)} {fmt(81 * G)} 0)'
                 f' (effects (font (size 1.5 1.5)) (justify left bottom)) (uuid "{uid("footer")}"))')

    sch = ('(kicad_sch (version 20250114) (generator "gen_schematic.py") (generator_version "9.0")\n'
           f'(uuid "{ROOT_UUID}") (paper "A4")\n'
           '(title_block (title "ZX Spectrum tape-port modem: SuperMini carrier") (rev "B") (comment 1 "See hardware/DESIGN.md"))\n'
           '(lib_symbols\n' + '\n'.join(libs.values()) + '\n)\n'
           + '\n'.join(items) +
           '\n(sheet_instances (path "/" (page "1")))\n(embedded_fonts no)\n)\n')
    with open(OUT, 'w', encoding='utf-8', newline='\n') as f:
        f.write(sch)
    pro = os.path.join(HERE, PROJECT + '.kicad_pro')
    if not os.path.exists(pro):                       # KiCad fills in every other setting
        with open(pro, 'w', encoding='utf-8', newline='\n') as f:
            f.write('{\n  "meta": {\n    "filename": "%s.kicad_pro",\n    "version": 3\n  }\n}\n' % PROJECT)
    print(f'wrote {OUT}: {sum(1 for r in PARTS if not r.startswith("#"))} parts, {len(split)} wire segments, '
          f'{counter[0]} power symbols + labels')

if __name__ == '__main__':
    main()
