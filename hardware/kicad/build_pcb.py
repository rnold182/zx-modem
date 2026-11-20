"""Build the rev B board (zx-modem.kicad_pcb): footprints, nets, outline, placement, rules.

Usage (from the repo root), with KiCad's own Python (it has the pcbnew module):
  "C:/Program Files/KiCad/10.0/bin/python.exe" -I hardware/kicad/build_pcb.py

Nets come from PARTS in gen_schematic.py, the same table the schematic is built
from, so board and schematic can't disagree (check_netlist.py checks the schematic;
this script asserts every pad it wires exists). Routing is a separate step.

Rev B is a carrier board for an ESP32-S3 SuperMini (soldered on by hand).
Board coordinates: mm, origin at the top-left corner, y down.
  left   : SuperMini, USB-C flush with the left edge, antenna end toward the middle
           (no copper under the antenna; no top-side traces or vias under the module)
  middle : MIC front end, comparator, bias, TX driver, PLAY debounce (0805 parts)
  right  : MIC jack (top) and EAR jack (below), PJ-307, openings facing out; PLAY button bottom middle
"""
import os, sys
import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from gen_schematic import PARTS                      # noqa: E402

FPLIB = os.environ.get('KICAD_SHARE', 'C:/Program Files/KiCad/10.0/share/kicad') + '/footprints/'
OUT = os.path.join(HERE, 'zx-modem.kicad_pcb')
W, H = 53.0, 26.0                                     # board size
MOD = (11.26, 12.5)                                   # SuperMini centre: its 22.52 mm length spans x 0..22.52
JACK_X = W - 5.85                                     # PJ-307 origin: body front (local x -5.85) on the right edge

# ref: (x, y, rotation) in board mm. 'usb_left' / 'nose_right' parts get their rotation chosen
# from their own geometry (see main()).
PLACE = {
    'U1': (MOD[0], MOD[1], 'usb_left'),
    'J3': (JACK_X, 6.4, 'nose_right'), 'J2': (JACK_X, 19.5, 'nose_right'),
    'SW3': (37.0, 22.6, 0),
    # MIC chain runs right to left, from the jack toward the comparator and the module
    'R20': (37.2, 1.6, 0), 'C7': (33.2, 1.6, 0), 'C8': (29.2, 1.6, 0), 'R7': (25.2, 1.6, 0),
    'R8': (25.2, 4.6, 0), 'R14': (29.2, 4.6, 0), 'C11': (33.2, 4.6, 0), 'R17': (37.2, 4.6, 0),
    'C10': (25.2, 8.0, 0), 'U4': (31.2, 8.0, 0), 'D1': (36.6, 8.0, 0),
    'R9': (25.2, 11.4, 0), 'R10': (29.2, 11.4, 0), 'C9': (33.2, 11.4, 0), 'R11': (37.2, 11.4, 0),
    # TX: module -> clamp -> 220R -> EAR jack
    'R12': (25.2, 14.8, 0), 'D2': (30, 14.8, 0), 'R5': (34.4, 14.8, 0), 'R6': (38, 14.8, 0),
    # PLAY: pull-up, debounce, series R, button
    'R18': (25.2, 18.2, 0), 'C12': (29.2, 18.2, 0), 'R19': (33.2, 18.2, 0),
}
# Silkscreen labels for the user: (text, x, y, angle).
LABELS = [('MIC', 40.7, 6.4, 90), ('EAR', 40.7, 17.0, 90),
          ('PLAY', 32.4, 22.6, 90), ('ZX MODEM rev B', 11.0, 24.3, 0)]
HOLES = []                                            # small board: no mounting holes

def load_fp(fpid):
    lib, name = fpid.split(':')
    path = os.path.join(HERE, 'zx-modem.pretty') if lib == 'zx-modem' else FPLIB + lib + '.pretty'
    fp = pcbnew.FootprintLoad(path, name)
    assert fp, fpid
    fp.SetFPID(pcbnew.LIB_ID(lib, name))
    return fp

def mm(v): return pcbnew.FromMM(v)

def fab_box(fp):
    xs, ys = [], []
    for it in fp.GraphicalItems():
        if it.GetLayer() == pcbnew.F_Fab and it.GetClass() == 'PCB_SHAPE':
            for p in (it.GetStart(), it.GetEnd()):
                xs.append(pcbnew.ToMM(p.x)); ys.append(pcbnew.ToMM(p.y))
    return min(xs), min(ys), max(xs), max(ys)

def place_refs(board):
    """Put each reference label where it doesn't sit on pads, parts or other labels.

    Text is JLCPCB's legible minimum (1.0 mm high, 0.15 mm stroke). For each part, try
    above / below / left / right of its courtyard and take the first spot that is clear
    of every pad, every other courtyard and every label already placed, and inside the board.
    """
    edge = board.GetBoardEdgesBoundingBox()
    taken = [t.GetBoundingBox() for t in board.GetDrawings()   # user labels placed first
             if t.GetClass() == 'PCB_TEXT' and t.GetLayer() == pcbnew.F_SilkS]
    def clear(box, me):
        if not edge.Contains(box.GetOrigin()) or not edge.Contains(box.GetEnd()): return False
        for fp in board.GetFootprints():
            for p in fp.Pads():
                if p.GetBoundingBox().Inflate(mm(0.15)).Intersects(box): return False
            if fp is not me:
                cy = fp.GetCourtyard(pcbnew.F_CrtYd)
                if cy.OutlineCount() and cy.BBox().Intersects(box): return False
        return not any(t.Intersects(box) for t in taken)
    fps = sorted(board.GetFootprints(), key=lambda f: f.GetReference())
    for fp in fps:
        ref = fp.Reference()
        if fp.GetReference().startswith('H'):         # mounting holes need no label
            ref.SetVisible(False); continue
        ref.SetTextSize(pcbnew.VECTOR2I(mm(1.0), mm(1.0))); ref.SetTextThickness(mm(0.15))
        ref.SetTextAngleDegrees(0)
        cy = fp.GetCourtyard(pcbnew.F_CrtYd)
        bb = cy.BBox() if cy.OutlineCount() else fp.GetBoundingBox(False)
        c = bb.GetCenter()
        half_w = mm(0.5) * len(fp.GetReference()) // 2 + mm(0.4)
        cand = [(c.x, bb.GetTop() - mm(0.8)), (c.x, bb.GetBottom() + mm(0.8)),
                (bb.GetLeft() - half_w - mm(0.3), c.y), (bb.GetRight() + half_w + mm(0.3), c.y),
                (c.x, bb.GetTop() - mm(1.9)), (c.x, bb.GetBottom() + mm(1.9))]
        for x, y in cand:
            ref.SetPosition(pcbnew.VECTOR2I(int(x), int(y)))
            box = ref.GetBoundingBox()
            if clear(box, fp):
                taken.append(box); break
        else:                                         # nowhere clear: keep the label on Fab only
            ref.SetLayer(pcbnew.F_Fab)

def name_unconnected_pads(board, netlist=os.path.join(HERE, 'zx-modem.net')):
    """Give each unused pin the 'unconnected-(...)' net the schematic gives it.

    Pure bookkeeping (these pads have no copper attached), so KiCad's schematic-parity
    check and "Update PCB from schematic" see no differences. Needs the netlist exported
    by kicad-cli (see check_netlist.py); returns how many pads were named.
    """
    import re
    text = re.sub(r'\s+', ' ', open(netlist, encoding='utf-8').read())
    named = 0
    for chunk in text.split('(net (code ')[1:]:
        name = re.search(r'\(name "([^"]*)"\)', chunk).group(1)
        if not name.startswith('unconnected-('): continue
        for ref, pin in re.findall(r'\(node \(ref "([^"]*)"\) \(pin "([^"]*)"\)', chunk):
            fp = board.FindFootprintByReference(ref)
            n = board.FindNet(name)
            if not n:
                n = pcbnew.NETINFO_ITEM(board, name); board.Add(n)
            for p in fp.Pads():
                if p.GetNumber() == pin:
                    assert p.GetNetCode() == 0, f'{ref}.{pin} already has a net'
                    p.SetNet(n); named += 1
    return named

def main():
    board = pcbnew.BOARD()
    ds = board.GetDesignSettings()
    # JLCPCB 2-layer standard capabilities, with margin
    ds.m_TrackMinWidth = mm(0.15); ds.m_MinClearance = mm(0.15)
    ds.m_ViasMinSize = mm(0.6); ds.m_MinThroughDrill = mm(0.3); ds.m_CopperEdgeClearance = mm(0.3)
    ds.SetCopperLayerCount(2)

    # Net classes: signals 0.25 mm; supply nets 0.5 mm.
    nsets = ds.m_NetSettings
    dflt = nsets.GetDefaultNetclass()
    dflt.SetTrackWidth(mm(0.25)); dflt.SetClearance(mm(0.2)); dflt.SetViaDiameter(mm(0.6)); dflt.SetViaDrill(mm(0.3))
    pwr = pcbnew.NETCLASS('Power')
    pwr.SetTrackWidth(mm(0.5)); pwr.SetClearance(mm(0.2)); pwr.SetViaDiameter(mm(0.8)); pwr.SetViaDrill(mm(0.4))
    nsets.SetNetclass('Power', pwr)
    for n in ('GND', '3V3'):
        nsets.SetNetclassPatternAssignment(n, 'Power')

    nets = {}
    def net(name):
        if name not in nets:
            n = pcbnew.NETINFO_ITEM(board, name); board.Add(n); nets[name] = n
        return nets[name]

    for ref, (lib_id, value, fpid, lcsc, conns, _, flags) in PARTS.items():
        if flags.get('power'): continue
        fp = load_fp(fpid)
        fp.SetReference(ref); fp.SetValue(value)
        fp.SetField('LCSC', lcsc)                     # empty for J4 / R6, like the schematic
        fp.GetField('LCSC').SetVisible(False)         # for the BOM only, not the silkscreen
        pads = {p.GetNumber() for p in fp.Pads()}
        missing = set(conns) - pads
        assert not missing, f'{ref}: footprint {fpid} has no pad(s) {missing}'
        for p in fp.Pads():
            if p.GetNumber() in conns: p.SetNet(net(conns[p.GetNumber()]))
        if flags.get('dnp'): fp.SetDNP(True); fp.SetExcludedFromPosFiles(True); fp.SetExcludedFromBOM(True)
        if not flags.get('in_bom', True): fp.SetExcludedFromPosFiles(True); fp.SetExcludedFromBOM(True)
        x, y, rot = PLACE[ref]
        if rot == 'usb_left':
            # footprint has USB-C at -y; pick the rotation that puts pad 1 (next to USB-C)
            # on the left, i.e. the USB end at the left board edge
            for r in (90, 270):
                fp.SetOrientationDegrees(r); fp.SetPosition(pcbnew.VECTOR2I(0, 0))
                p1 = [p for p in fp.Pads() if p.GetNumber() == '1'][0].GetPosition()
                if p1.x < 0: break
        elif rot == 'nose_right':
            # PJ-307: pin 1 (sleeve) sits alone next to the opening, 5.3 mm in front of the
            # back row (pins 2-5). Pick the rotation that puts pin 1 5.3 mm to the RIGHT of
            # pin 2, so the opening points at +x (the right edge).
            for r in (0, 90, 180, 270):
                fp.SetOrientationDegrees(r); fp.SetPosition(pcbnew.VECTOR2I(0, 0))
                pad = {p.GetNumber(): p.GetPosition() for p in fp.Pads() if p.GetNumber()}
                if pcbnew.ToMM(pad['1'].x - pad['2'].x) > 5.0: break
            else:
                raise AssertionError(f'{ref}: no rotation points the jack opening right')
        else:
            fp.SetOrientationDegrees(rot)
        fp.SetPosition(pcbnew.VECTOR2I(mm(x), mm(y)))
        board.Add(fp)

    for i, (hx, hy) in enumerate(HOLES):
        fp = load_fp('MountingHole:MountingHole_3.2mm_M3')
        fp.SetReference(f'H{i + 1}'); fp.SetValue('M3')
        fp.SetExcludedFromPosFiles(True); fp.SetExcludedFromBOM(True)
        fp.SetBoardOnly(True)                         # not in the schematic, and that's intended
        fp.SetPosition(pcbnew.VECTOR2I(mm(hx), mm(hy))); board.Add(fp)

    # outline with 1 mm corner radius
    r = 1.0
    segs = [((r, 0), (W - r, 0)), ((W, r), (W, H - r)), ((W - r, H), (r, H)), ((0, H - r), (0, r))]
    for (a, b) in segs:
        s = pcbnew.PCB_SHAPE(board); s.SetShape(pcbnew.SHAPE_T_SEGMENT); s.SetLayer(pcbnew.Edge_Cuts)
        s.SetStart(pcbnew.VECTOR2I(mm(a[0]), mm(a[1]))); s.SetEnd(pcbnew.VECTOR2I(mm(b[0]), mm(b[1])))
        s.SetWidth(mm(0.1)); board.Add(s)
    def rule_area(name, layers, x0, y0, x1, y1, fills):
        z = pcbnew.ZONE(board)
        z.SetIsRuleArea(True); z.SetZoneName(name)
        z.SetDoNotAllowTracks(True); z.SetDoNotAllowVias(True); z.SetDoNotAllowPads(False)
        z.SetDoNotAllowFootprints(False); z.SetDoNotAllowZoneFills(not fills)
        ls = pcbnew.LSET()
        for l in layers: ls.AddLayer(l)
        z.SetLayerSet(ls)
        o = z.Outline(); o.NewOutline()
        for px, py in ((x0, y0), (x1, y0), (x1, y1), (x0, y1)): o.Append(mm(px), mm(py))
        board.Add(z)
    # No copper at all under the SuperMini's antenna end (its last ~5 mm), both layers.
    rule_area('antenna_keepout', (pcbnew.F_Cu, pcbnew.B_Cu), MOD[0] + 6.26, MOD[1] - 6.0, MOD[0] + 11.36, MOD[1] + 6.0, False)
    # The module is soldered flat: no top-side traces or vias between its two pad rows
    # (its underside has bare pads). Bottom-side traces are fine; ground pour stays (it's under mask).
    rule_area('under_module', (pcbnew.F_Cu,), 0.3, MOD[1] - 6.3, MOD[0] + 11.36, MOD[1] + 6.3, True)

    k = r * (1 - 2 ** -0.5)                           # corner arcs as start / mid / end points
    for st, md, en in [((0, r), (k, k), (r, 0)), ((W - r, 0), (W - k, k), (W, r)),
                       ((W, H - r), (W - k, H - k), (W - r, H)), ((r, H), (k, H - k), (0, H - r))]:
        a = pcbnew.PCB_SHAPE(board); a.SetShape(pcbnew.SHAPE_T_ARC); a.SetLayer(pcbnew.Edge_Cuts)
        a.SetArcGeometry(*(pcbnew.VECTOR2I(mm(px), mm(py)) for px, py in (st, md, en)))
        a.SetWidth(mm(0.1)); board.Add(a)

    for text, x, y, ang in LABELS:
        t = pcbnew.PCB_TEXT(board); t.SetText(text); t.SetLayer(pcbnew.F_SilkS)
        t.SetTextSize(pcbnew.VECTOR2I(mm(1.0), mm(1.0))); t.SetTextThickness(mm(0.15))
        t.SetTextAngleDegrees(ang); t.SetPosition(pcbnew.VECTOR2I(mm(x), mm(y))); board.Add(t)
    place_refs(board)
    name_unconnected_pads(board)
    board.Save(OUT)
    print(f'wrote {OUT}: {len(board.GetFootprints())} footprints, {len(nets)} nets')

if __name__ == '__main__':
    main()
