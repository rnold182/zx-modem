"""Make the JLCPCB order files in hardware/fab/ from the schematic and the routed board.

Usage (from the repo root):  python -I hardware/kicad/make_fab.py

Writes:
  fab/zx-modem-gerbers.zip   Gerbers (2 copper, mask, paste, silk, outline) + Excellon drill
  fab/zx-modem-bom.csv       JLCPCB BOM: Comment, Designator, Footprint, JLCPCB Part #
  fab/zx-modem-cpl.csv       JLCPCB pick and place: Designator, Mid X, Mid Y, Layer, Rotation
  fab/zx-modem-hand-solder.csv  parts you solder yourself (SuperMini, jacks)

Parts without an LCSC number (the hand-soldered SuperMini and jacks, DNP R6) are left out
of the BOM and CPL, so JLCPCB places nothing there.
Positions and rotations are corrected to JLCPCB's own footprints (see jlc_fit.py), so their
preview should show every part on its pads; check it anyway before ordering.
"""
import csv, glob, json, math, os, shutil, subprocess, sys, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
FAB = os.path.join(os.path.dirname(HERE), 'fab')
SCH = os.path.join(HERE, 'zx-modem.kicad_sch')
PCB = os.path.join(HERE, 'zx-modem.kicad_pcb')
CLI = os.environ.get('KICAD_CLI', 'C:/Program Files/KiCad/10.0/bin/kicad-cli.exe')
LAYERS = 'F.Cu,B.Cu,F.Paste,B.Paste,F.Silkscreen,B.Silkscreen,F.Mask,B.Mask,Edge.Cuts'

def rot_ccw(x, y, deg):
    """Rotate counter-clockwise as seen on screen, in a y-down frame (same as jlc_fit.rot)."""
    a = math.radians(deg); c, s = math.cos(a), math.sin(a)
    return x * c + y * s, -x * s + y * c

def run(*args):
    subprocess.run([CLI, *args], check=True, stdout=subprocess.DEVNULL)

def main():
    tmp = os.path.join(FAB, 'tmp')
    shutil.rmtree(tmp, ignore_errors=True); os.makedirs(tmp)

    # Gerbers + drill, zipped flat (JLCPCB wants the files at the zip's top level)
    run('pcb', 'export', 'gerbers', '--layers', LAYERS, '-o', tmp + os.sep, PCB)
    run('pcb', 'export', 'drill', '--format', 'excellon', '--excellon-units', 'mm', '-o', tmp + os.sep, PCB)
    files = sorted(glob.glob(os.path.join(tmp, '*.g*')) + glob.glob(os.path.join(tmp, '*.drl')))
    with zipfile.ZipFile(os.path.join(FAB, 'zx-modem-gerbers.zip'), 'w', zipfile.ZIP_DEFLATED) as z:
        for f in files: z.write(f, os.path.basename(f))

    # BOM, grouped by value + footprint + LCSC number
    raw_bom = os.path.join(tmp, 'bom.csv')
    run('sch', 'export', 'bom', '--exclude-dnp', '--fields', 'Value,Reference,Footprint,LCSC',
        '--labels', 'Comment,Designator,Footprint,JLCPCB Part #', '--group-by', 'Value,Footprint,LCSC',
        '--ref-range-delimiter', '', '-o', raw_bom, SCH)
    rows = list(csv.DictReader(open(raw_bom, encoding='utf-8')))
    merged = {}                                       # one line per LCSC part: BOOT/RESET/PLAY share a switch
    for r in rows:
        lcsc = r['JLCPCB Part #']
        if not lcsc: continue
        m = merged.setdefault(lcsc, {'comments': [], 'refs': [], 'fp': r['Footprint'].split(':')[-1]})
        if r['Comment'] not in m['comments']: m['comments'].append(r['Comment'])
        m['refs'] += [x.strip() for x in r['Designator'].split(',')]
    bom_refs = set()
    with open(os.path.join(FAB, 'zx-modem-bom.csv'), 'w', newline='', encoding='utf-8') as f:
        w = csv.writer(f); w.writerow(['Comment', 'Designator', 'Footprint', 'JLCPCB Part #'])
        for lcsc, m in merged.items():
            w.writerow([' / '.join(m['comments']), ','.join(m['refs']), m['fp'], lcsc])
            bom_refs.update(m['refs'])

    # CPL: every placed part that's on the BOM, corrected to JLCPCB's footprint origins and
    # zero rotations (jlc_corrections.json, made by jlc_fit.py from their footprint data).
    # JLCPCB puts their footprint origin on (Mid X, Mid Y) and turns it by Rotation. If their
    # pads are e = rot(k, phi) + d in terms of ours, then rotation = ours - phi and
    # position = ours - rot(d, rotation).
    fix = json.load(open(os.path.join(HERE, 'jlc_corrections.json'), encoding='utf-8'))
    lcsc_of = {ref: lcsc for lcsc, m in merged.items() for ref in m['refs']}
    raw_pos = os.path.join(tmp, 'pos.csv')
    run('pcb', 'export', 'pos', '--format', 'csv', '--units', 'mm', '--side', 'both', '--exclude-dnp',
        '-o', raw_pos, PCB)
    placed = set()
    with open(os.path.join(FAB, 'zx-modem-cpl.csv'), 'w', newline='', encoding='utf-8') as f:
        w = csv.writer(f); w.writerow(['Designator', 'Mid X', 'Mid Y', 'Layer', 'Rotation'])
        for r in csv.DictReader(open(raw_pos, encoding='utf-8')):
            if r['Ref'] not in bom_refs: continue
            assert r['Side'] == 'top', 'corrections assume top-side parts'
            x, y, rot = float(r['PosX']), -float(r['PosY']), float(r['Rot'])   # y down, like the board
            c = fix.get(lcsc_of[r['Ref']])
            if c:
                rot = (rot - c['phi']) % 360
                ox, oy = rot_ccw(c['dx'], c['dy'], rot)
                x, y = x - ox, y - oy
            w.writerow([r['Ref'], f'{x:.3f}mm', f'{-y:.3f}mm', 'Top', f'{rot:g}'])
            placed.add(r['Ref'])
    shutil.rmtree(tmp)

    # Parts you solder yourself (flag 'hand' in PARTS): not in the JLCPCB files above.
    sys.path.insert(0, HERE)
    from gen_schematic import PARTS
    hand = {}
    for ref, (_, value, fpid, _, _, _, flags) in PARTS.items():
        if flags.get('hand'):
            hand.setdefault((flags.get('mpn', value), fpid.split(':')[-1]), []).append(ref)
    with open(os.path.join(FAB, 'zx-modem-hand-solder.csv'), 'w', newline='', encoding='utf-8') as f:
        w = csv.writer(f); w.writerow(['Part to buy', 'Qty', 'Designator', 'Footprint'])
        for (mpn, fp), refs in hand.items():
            w.writerow([mpn, len(refs), ','.join(refs), fp])

    missing = bom_refs - placed
    print(f'gerbers: {len(files)} files zipped; BOM: {len(bom_refs)} parts; CPL: {len(placed)} placements')
    if missing:
        print('ERROR: on the BOM but not on the board:', sorted(missing)); sys.exit(1)

if __name__ == '__main__':
    main()
