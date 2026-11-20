"""Autoroute zx-modem.kicad_pcb with Freerouting, then add the ground pours.

Usage (from the repo root), with KiCad's own Python:
  "C:/Program Files/KiCad/10.0/bin/python.exe" -I hardware/kicad/route_pcb.py

Needs Freerouting 2.5.0 (Java 25). Set FREEROUTING_JAR and JAVA25 if they live elsewhere.
Steps: export Specctra DSN -> Freerouting (headless, analytics off) -> import the SES
session -> GND pour on both layers, stitched with vias -> fill zones -> save.
Run build_pcb.py first; this script routes whatever that placed.
"""
import os, subprocess, sys
import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
PCB = os.path.join(HERE, 'zx-modem.kicad_pcb')
DSN = os.path.join(HERE, 'zx-modem.dsn')
SES = os.path.join(HERE, 'zx-modem.ses')
JAR = os.environ.get('FREEROUTING_JAR', 'freerouting-2.5.0.jar')
JAVA = os.environ.get('JAVA25', 'C:/Program Files/Microsoft/jdk-25.0.5.21-hotspot/bin/java.exe')
PASSES = int(os.environ.get('ROUTE_PASSES', '100'))

def mm(v): return pcbnew.FromMM(v)

def add_gnd_pours(board):
    """GND zone on both layers over the whole board, plus a stitching via grid."""
    gnd = board.FindNet('GND')
    bb = board.GetBoardEdgesBoundingBox()
    for layer in (pcbnew.F_Cu, pcbnew.B_Cu):
        z = pcbnew.ZONE(board)
        z.SetLayer(layer); z.SetNet(gnd); z.SetZoneName(f'GND_{board.GetLayerName(layer)}')
        z.SetLocalClearance(mm(0.3)); z.SetMinThickness(mm(0.25))
        z.SetPadConnection(pcbnew.ZONE_CONNECTION_THERMAL)
        z.SetThermalReliefGap(mm(0.3)); z.SetThermalReliefSpokeWidth(mm(0.4))
        z.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_ALWAYS)
        o = z.Outline(); o.NewOutline()
        for x, y in ((bb.GetLeft(), bb.GetTop()), (bb.GetRight(), bb.GetTop()),
                     (bb.GetRight(), bb.GetBottom()), (bb.GetLeft(), bb.GetBottom())):
            o.Append(x, y)
        board.Add(z)
    # Stitching vias on a 5 mm grid wherever a via fits clear of everything else, so the
    # two pours act as one ground and top-side islands get tied down.
    vias = 0
    step = mm(5.0)
    x = bb.GetLeft() + mm(2.5)
    while x < bb.GetRight() - mm(1.5):
        y = bb.GetTop() + mm(2.5)
        while y < bb.GetBottom() - mm(1.5):
            v = pcbnew.PCB_VIA(board)
            v.SetPosition(pcbnew.VECTOR2I(x, y)); v.SetWidth(mm(0.6)); v.SetDrill(mm(0.3)); v.SetNet(gnd)
            if fits(board, v): board.Add(v); vias += 1
            y += step
        x += step
    return vias

def fits(board, via):
    """True if the via keeps 0.3 mm from every non-GND copper item and 1 mm from the edge,
    and sits outside every footprint courtyard (so it never lands under a part)."""
    pos = via.GetPosition(); r = via.GetWidth(pcbnew.F_Cu) // 2
    gnd = via.GetNetCode()
    bb = board.GetBoardEdgesBoundingBox()
    if (pos.x - r < bb.GetLeft() + mm(1) or pos.x + r > bb.GetRight() - mm(1) or
            pos.y - r < bb.GetTop() + mm(1) or pos.y + r > bb.GetBottom() - mm(1)):
        return False
    for z in board.Zones():                           # respect keep-outs (antenna ground strip)
        if z.GetIsRuleArea() and z.GetDoNotAllowVias() and z.Outline().Collide(pcbnew.VECTOR2I(pos.x, pos.y), r):
            return False
    for fp in board.GetFootprints():
        for side in (pcbnew.F_CrtYd, pcbnew.B_CrtYd):
            cy = fp.GetCourtyard(side)
            if cy.OutlineCount() and cy.Collide(pcbnew.VECTOR2I(pos.x, pos.y), r + mm(0.2)):
                return False
        for p in fp.Pads():
            if p.GetBoundingBox().Inflate(r + mm(0.3)).Contains(pos): return False
    for t in board.GetTracks():
        if t.GetClass() == 'PCB_VIA':                 # any via, GND included: keep the drills apart
            if (t.GetPosition() - pos).EuclideanNorm() < r + t.GetWidth(pcbnew.F_Cu) // 2 + mm(0.5): return False
            continue
        if t.GetNetCode() == gnd: continue
        if t.HitTest(pos, r + mm(0.3)): return False
    return True

def drop_edge_gnd_tracks(board, clearance=0.3):
    """Remove GND track segments closer than `clearance` mm to the board edge.

    Freerouting keeps only its class clearance (0.2 mm) from the outline, while KiCad's
    edge rule is 0.3 mm. The only tracks it puts there are GND links between button pads,
    which the GND pours connect anyway; DRC afterwards proves nothing became unconnected.
    """
    # The outline is a rectangle, so a straight segment comes closest to an edge at one of
    # its ends: plain arithmetic, no SWIG shape objects (those upset later SWIG calls).
    bb = board.GetBoardEdgesBoundingBox()
    bb.Inflate(-mm(0.05))                             # the box includes half the 0.1 mm outline stroke
    gnd = board.FindNet('GND').GetNetCode()
    doomed = []
    for t in board.GetTracks():
        if t.GetClass() != 'PCB_TRACK' or t.GetNetCode() != gnd: continue
        for p in (t.GetStart(), t.GetEnd()):
            d = min(p.x - bb.GetLeft(), bb.GetRight() - p.x, p.y - bb.GetTop(), bb.GetBottom() - p.y)
            if d - t.GetWidth() / 2 < mm(clearance):
                doomed.append(t); break
    for t in doomed: board.Remove(t)
    return len(doomed)

def main():
    board = pcbnew.LoadBoard(PCB)
    assert pcbnew.ExportSpecctraDSN(board, DSN), 'DSN export failed'
    cmd = [JAVA, '-jar', JAR, '-de', DSN, '-do', SES, '-mp', str(PASSES),
           '--gui.enabled=false', '--usage_and_diagnostic_data.disable_analytics=true']
    print('running:', ' '.join(cmd), flush=True)
    subprocess.run(cmd, check=True)
    board = pcbnew.LoadBoard(PCB)                     # reload: the SES applies to a clean board
    assert pcbnew.ImportSpecctraSES(board, SES), 'SES import failed'
    dropped = drop_edge_gnd_tracks(board)
    for t in board.GetTracks():                       # Freerouting sometimes necks a stub below
        if t.GetClass() == 'PCB_TRACK' and t.GetWidth() < mm(0.15):   # JLCPCB's 0.15 mm minimum
            t.SetWidth(mm(0.15))
    n = add_gnd_pours(board)
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    board.Save(PCB)
    print(f'routed, {len(board.GetTracks())} track/via items, {dropped} edge GND segments dropped, '
          f'{n} stitching vias; saved {PCB}')

if __name__ == '__main__':
    main()
