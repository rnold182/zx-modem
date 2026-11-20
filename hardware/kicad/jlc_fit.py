"""Work out JLCPCB placement corrections by fitting their footprints onto ours.

Usage (from the repo root), with KiCad's own Python:
  "C:/Program Files/KiCad/10.0/bin/python.exe" -I hardware/kicad/jlc_fit.py [easyeda_dir]
  "C:/Program Files/KiCad/10.0/bin/python.exe" -I hardware/kicad/jlc_fit.py --check   (after make_fab.py)

JLCPCB places each part by putting the origin of *their* (EasyEDA) footprint on the CPL
coordinate and turning it by the CPL rotation. Their origin and zero-rotation often differ
from KiCad's (the ESP32 module's origin is 3.6 mm away; jacks are 90 degrees off), so the
raw KiCad position file puts parts in the wrong place.

For each LCSC part this script takes the pad positions of both footprints, tries the four
rotations, aligns the pad patterns and keeps the rotation where every pad lands on a pad
(tie-break: matching pad numbers). It prints the correction (dRot, offset) and the residual
error, and writes jlc_corrections.json for make_fab.py.

easyeda_dir holds <LCSC>.json files from
  https://easyeda.com/api/products/<LCSC>/components?version=6.4.19.5
"""
import json, math, os, sys
import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from gen_schematic import PARTS                      # noqa: E402

U = 0.254                                             # EasyEDA unit = 10 mil
FPLIB = 'C:/Program Files/KiCad/10.0/share/kicad/footprints/'
PASSIVE = ('Resistor_SMD:', 'Capacitor_SMD:')         # symmetric two-pad parts: nothing to fix

def rot(x, y, deg):
    """Rotate counter-clockwise as seen on screen, in a y-down frame."""
    a = math.radians(deg); c, s = math.cos(a), math.sin(a)
    return x * c + y * s, -x * s + y * c

def eda_pin_names(path):
    """{pad number: pin name} from the part's own EasyEDA symbol (e.g. LED '2' -> 'K')."""
    shapes = json.load(open(path, encoding='utf-8'))['result']['dataStr']['shape']
    out = {}
    for sh in shapes:
        if sh.startswith('P~'):
            seg = sh.split('^^')
            num = seg[0].split('~')[3]
            name = seg[3].split('~')[4] if len(seg) > 3 and len(seg[3].split('~')) > 4 else ''
            out[num] = name
    return out

# KiCad's own pin functions for the parts where pad numbers alone don't fix the orientation
# (two-pad polarised parts: both 0 and 180 degrees fit the pads, only the pin names decide).
KICAD_PIN_NAMES = {'Device:LED': {'1': 'K', '2': 'A'}}

def eda_pads(path):
    ds = json.load(open(path, encoding='utf-8'))['result']['packageDetail']['dataStr']
    hx, hy = float(ds['head']['x']), float(ds['head']['y'])
    out = []
    for sh in ds['shape']:
        if sh.startswith('PAD~'):
            f = sh.split('~')
            out.append((f[8], (float(f[2]) - hx) * U, (float(f[3]) - hy) * U))
    return out

def kicad_pads(fpid):
    lib, name = fpid.split(':')
    libdir = os.path.join(HERE, lib + '.pretty') if lib == 'zx-modem' else FPLIB + lib + '.pretty'
    fp = pcbnew.FootprintLoad(libdir, name)        # zx-modem: this project's own footprints
    seen, out = set(), []
    for p in fp.Pads():
        if not p.GetNumber(): continue                # unnumbered = mechanical holes / thermal vias
        x, y = round(pcbnew.ToMM(p.GetPosition().x), 3), round(pcbnew.ToMM(p.GetPosition().y), 3)
        if (x, y) in seen: continue                   # stacked pads (USB-C A1/B12) count once
        seen.add((x, y)); out.append((p.GetNumber(), x, y))
    return out

def centre(pts):
    xs = [p[1] for p in pts]; ys = [p[2] for p in pts]
    return (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2

def fit(kp, ep, rename=None):
    """Best (phi, dx, dy, err, numbers_agree): e = rot(k, phi) + d.

    rename maps KiCad pad numbers to the JLC pad numbers with the same function, so the
    number tie-break compares like with like (needed for LEDs, where the pads are swapped).
    """
    if rename: kp = [(rename.get(n, n), x, y) for n, x, y in kp]
    ecx, ecy = centre(ep)
    best = None
    for phi in (0, 90, 180, 270):
        kr = [(n, *rot(x, y, phi)) for n, x, y in kp]
        kcx, kcy = centre(kr)
        dx, dy = ecx - kcx, ecy - kcy
        err, agree = 0.0, 0
        for n, x, y in kr:
            m = min(ep, key=lambda e: (e[1] - x - dx) ** 2 + (e[2] - y - dy) ** 2)
            err = max(err, math.hypot(m[1] - x - dx, m[2] - y - dy))
            agree += (m[0] == n)
        cand = (round(err, 2), -agree, phi, dx, dy)
        if best is None or cand < best: best = cand
    err, nagree, phi, dx, dy = best
    return phi, dx, dy, err, -nagree

def main():
    edir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, 'easyeda')   # see the docstring
    done, out = set(), {}
    for ref, (_, value, fpid, lcsc, _, _, flags) in PARTS.items():
        if not lcsc or lcsc in done or fpid.startswith(PASSIVE): continue
        done.add(lcsc)
        path = os.path.join(edir, lcsc + '.json')
        kp, ep = kicad_pads(fpid), eda_pads(path)
        rename = None
        lib_id = PARTS[ref][0]
        if lib_id in KICAD_PIN_NAMES:                 # match pads by function, not number
            by_name = {v: k for k, v in eda_pin_names(path).items()}
            rename = {kn: by_name[name] for kn, name in KICAD_PIN_NAMES[lib_id].items()}
        phi, dx, dy, err, agree = fit(kp, ep, rename)
        out[lcsc] = {'phi': phi, 'dx': round(dx, 4), 'dy': round(dy, 4), 'err_mm': err,
                     'pads_kicad': len(kp), 'pads_jlc': len(ep), 'numbers_agree': agree, 'ref': ref}
        print(f'{lcsc:9s} {ref:5s} {fpid.split(":")[1][:38]:38s} phi {phi:3d}  d=({dx:6.2f},{dy:6.2f})'
              f'  err {err:.2f} mm  pads {len(kp)}/{len(ep)}  numbers agree {agree}/{len(kp)}')
    with open(os.path.join(HERE, 'jlc_corrections.json'), 'w', encoding='utf-8', newline='\n') as f:
        json.dump(out, f, indent=1, sort_keys=True)



def check(cpl_path, pcb_path, edir):
    """Place JLCPCB's footprints exactly as the CPL tells them and measure every pad against
    the board's real copper. Prints the worst pad error per part; for polarised two-pad parts
    it also checks that each JLC pin lands on the KiCad pad with the same function."""
    import csv
    board = pcbnew.LoadBoard(pcb_path)
    worst_all = 0.0
    for r in csv.DictReader(open(cpl_path, encoding='utf-8')):
        ref = r['Designator']; lib_id, _, fpid, lcsc, _, _, _ = PARTS[ref]
        path = os.path.join(edir, lcsc + '.json')
        if not os.path.exists(path): continue         # passives: nothing to check
        qx, qy, th = float(r['Mid X'][:-2]), -float(r['Mid Y'][:-2]), float(r['Rotation'])
        fp = board.FindFootprintByReference(ref)
        bpads = [(p.GetNumber(), pcbnew.ToMM(p.GetPosition().x), pcbnew.ToMM(p.GetPosition().y))
                 for p in fp.Pads() if p.GetNumber()]
        names = eda_pin_names(path)
        worst, wrong = 0.0, []
        for num, ex, ey in eda_pads(path):
            ox, oy = rot(ex, ey, th)
            px, py = qx + ox, qy + oy
            m = min(bpads, key=lambda b: (b[1] - px) ** 2 + (b[2] - py) ** 2)
            worst = max(worst, math.hypot(m[1] - px, m[2] - py))
            if lib_id in KICAD_PIN_NAMES and KICAD_PIN_NAMES[lib_id].get(m[0]) != names.get(num):
                wrong.append(f'JLC pin {names.get(num)} on KiCad pad {m[0]}')
        worst_all = max(worst_all, worst)
        print(f'{ref:5s} {lcsc:9s} worst pad error {worst:.2f} mm' + (f'  POLARITY WRONG: {wrong}' if wrong else ''))
    print(f'overall worst {worst_all:.2f} mm')

if __name__ == '__main__':
    if '--check' in sys.argv:                         # jlc_fit.py --check [easyeda_dir]
        args = [a for a in sys.argv[1:] if a != '--check']
        check(os.path.join(os.path.dirname(HERE), 'fab', 'zx-modem-cpl.csv'),
              os.path.join(HERE, 'zx-modem.kicad_pcb'), args[0] if args else os.path.join(HERE, 'easyeda'))
    else:
        main()
