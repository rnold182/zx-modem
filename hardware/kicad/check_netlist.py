"""Cross-check KiCad's netlist against the PARTS table in gen_schematic.py.

Usage (from the repo root):
  kicad-cli sch export netlist --format kicadsexpr -o hardware/kicad/zx-modem.net hardware/kicad/zx-modem.kicad_sch
  python -I hardware/kicad/check_netlist.py

Why: ERC only proves the schematic is self-consistent. This proves that what KiCad
actually connected (pin by pin) is exactly what the table says, so a mis-placed
label or a wrong pin number can't slip through.
"""
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_schematic import PARTS

net_text = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'zx-modem.net'), encoding='utf-8').read()
net_text = re.sub(r'\s+', ' ', net_text)             # KiCad writes one token per line
actual = {}                                           # (ref, pin) -> net name
for chunk in net_text.split('(net (code ')[1:]:
    name = re.search(r'\(name "([^"]*)"\)', chunk).group(1).lstrip('/')
    for ref, pin in re.findall(r'\(node \(ref "([^"]*)"\) \(pin "([^"]*)"\)', chunk):
        actual[(ref, pin)] = name

errors = 0
expected = {}
for ref, (_, _, _, _, conns, _, flags) in PARTS.items():
    if flags.get('power'): continue                   # PWR_FLAG has no footprint, so no netlist node
    for pin, net in conns.items():
        expected[(ref, pin)] = net
for key, net in sorted(expected.items()):
    got = actual.get(key)
    if got != net:
        print(f'MISMATCH {key[0]}.{key[1]}: expected {net}, KiCad has {got}'); errors += 1
for key, got in sorted(actual.items()):
    if key not in expected and not got.startswith('unconnected-'):
        print(f'EXTRA {key[0]}.{key[1]} is on {got}, but the table leaves it unconnected'); errors += 1

nets = {}
for (ref, pin), net in expected.items():
    nets.setdefault(net, []).append(f'{ref}.{pin}')
for net, nodes in sorted(nets.items()):
    if len(nodes) < 2:
        print(f'SINGLE-NODE net {net}: {nodes}'); errors += 1
print(f'{len(expected)} connections, {len(nets)} nets checked: '
      + ('OK' if errors == 0 else f'{errors} problem(s)'))
sys.exit(1 if errors else 0)
