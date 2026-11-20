"""MIC front-end simulation for the tape-port modem board (rev B/C; rev A had the same network).

Usage:  python -I hardware/sim/frontend_sim.py [recording.wav]
        (default: host/tests/data/zx48k-save-test.wav)

Feeds a real 48K SAVE recording (left channel) through the analogue front end
and decodes the comparator output with ROM-style rules (pilot run >= 256, sync,
bit pairs classified by their summed length, XOR checksum). It prints exactly the
cases quoted in hardware/DESIGN.md ("MIC input").

Circuit modelled (absolute voltages, GND = 0):
  Vs (recording scaled to the given open-circuit p-p, plus optional 50 Hz hum)
   -- Rsrc (source impedance) -- Rin -- J -- C7 -- A -- C8 -- B
                                             R7 to VBIAS    R8 to VBIAS
                                                            D1 (BAT54S) clamps B to GND and 3V3
                                                            C11 via R14 (ADC pin, one-way lag)
  Comparator: IN- = B, IN+ = VBIAS + offset +/- hysteresis/2 (push-pull output).

Integration: backward Euler at 2x the WAV rate, with a Newton solve for node A each step.
That keeps the stiff diode clamp stable and, importantly, lets clamp current recharge
C8/C7 (the DC-restorer effect), which a "clamp a copy of B" model misses.
Diode: I = Is*(exp(V/nVt)-1), Is = 1e-7 A, nVt = 34.7 mV. That gives about 0.24 V at
0.1 mA and 0.32 V at 1 mA, close to the BAT54 datasheet curve.
"""
import array, math, os, random, sys, wave

V33 = 3.3
IS, NVT = 1e-7, 0.0347

def load(path):
    w = wave.open(path)
    fr, nc = w.getframerate(), w.getnchannels()
    raw = array.array('h', w.readframes(w.getnframes()))[0::nc]
    seg = raw[2 * fr:3 * fr]                       # pilot section, used for scaling
    return raw, fr, max(seg) - min(seg)

VLIN = 0.6                                         # above this the diode is extended linearly (~3 A, 92 S)
ILIN = IS * (math.exp(VLIN / NVT) - 1.0)
GLIN = IS / NVT * math.exp(VLIN / NVT)

def idiode(v):                                     # current through a diode, anode-cathode voltage v
    if v > VLIN: return ILIN + GLIN * (v - VLIN)
    return IS * (math.exp(v / NVT) - 1.0)

def didiode(v):
    if v > VLIN: return GLIN
    return IS / NVT * math.exp(v / NVT)

def simulate(raw, fr, pp, net, vpp, hum, hyst, rsrc, offset=0.003, noise=0.001, up=2, seed=1):
    R7, C7, R8, C8, VB, RIN = net['R7'], net['C7'], net['R8'], net['C8'], net['VB'], net['RIN']
    random.seed(seed)
    fs = fr * up; dt = 1.0 / fs; k = vpp / pp
    rs = rsrc + RIN
    k1 = 1.0 / (rs + dt / C7)
    v7 = -VB; v8 = 0.0                              # v7 = J - A, v8 = A - B; at rest J = 0 V (AC source), A = B = VB
    A = VB; g = VB
    st = 0; last = 0; edges = []
    bmin, bmax, imax, gmin, gmax = 9, -9, 0.0, 9, -9
    acc = 0.0; nacc = 0
    th_hi = VB + offset + hyst / 2; th_lo = VB + offset - hyst / 2
    tau_adc = 10e3 * 100e-12                       # R14 * C11
    n_total = (len(raw) - 1) * up
    for n in range(n_total):
        i, f = divmod(n, up)
        x = (raw[i] * (up - f) + raw[i + 1] * f) / up * k
        t = n * dt
        if hum: x += hum * vpp / 2 * math.sin(2 * math.pi * 50 * t)
        # Solve KCL at node B for A (backward Euler). f(A) is strictly decreasing, so a
        # bracketed Newton step with bisection fallback always converges.
        lo, hi = A - 50.0, A + 50.0
        dB = 1 + dt / C8 * (k1 + 1 / R7)
        for _ in range(100):
            i7 = (x - A - v7) * k1
            i8 = i7 - (A - VB) / R7
            B = A - v8 - dt * i8 / C8
            iD = idiode(B - V33) - idiode(-B)       # current leaving node B through the clamps
            fval = i8 - (B - VB) / R8 - iD
            if fval > 0: lo = A
            else: hi = A
            dfd = -(k1 + 1 / R7) - dB * (1 / R8 + didiode(B - V33) + didiode(-B))
            An = A - fval / dfd
            if not (lo < An < hi): An = (lo + hi) / 2
            if abs(An - A) < 1e-9: A = An; break
            A = An
        i7 = (x - A - v7) * k1
        i8 = i7 - (A - VB) / R7
        B = A - v8 - dt * i8 / C8
        iD = idiode(B - V33) - idiode(-B)
        v7 += dt * i7 / C7; v8 += dt * i8 / C8
        g += (B - g) * dt / (tau_adc + dt)          # GPIO5 node behind R14/C11
        if B < bmin: bmin = B
        if B > bmax: bmax = B
        if abs(iD) > imax: imax = abs(iD)
        if g < gmin: gmin = g
        if g > gmax: gmax = g
        if 2 * fs <= n < 5 * fs: acc += B; nacc += 1
        b = B + random.gauss(0, noise)
        if st == 0 and b > th_hi: st = 1; edges.append(n - last); last = n
        elif st == 1 and b < th_lo: st = 0; edges.append(n - last); last = n
    blocks = decode([e * 3.5e6 / fs for e in edges])
    return dict(blocks=blocks, bmin=bmin, bmax=bmax, imax=imax, gmin=gmin, gmax=gmax, shift=acc / nacc - VB)

def decode(T):
    res = []; i = 0
    while i < len(T):
        j = i
        while j < len(T) and 1700 < T[j] < 2700: j += 1
        if j - i < 256 or j + 1 >= len(T): i = j + 1; continue
        i = j
        if not (400 < T[i] < 1000 and 400 < T[i + 1] < 1100): i += 1; continue
        i += 2; bits = []
        while i + 1 < len(T):
            s = T[i] + T[i + 1]
            if 1000 < s < 2600: bits.append(0)
            elif 2600 <= s < 4500: bits.append(1)
            else: break
            i += 2
        by = bytes(int(''.join(map(str, bits[q:q + 8])), 2) for q in range(0, len(bits) // 8 * 8, 8))
        x = 0
        for b in by: x ^= b
        res.append((len(by), x == 0 and len(by) > 0))
    return res

# Expected: header 19 bytes + data 57 bytes, both with good checksums.
def ok(blocks): return blocks == [(19, True), (57, True)]

NETS = {
    # previous proposal: LM393, bias 1.06 V, low input impedance, no input resistor
    'draft': dict(R7=6.8e3, C7=100e-9, R8=68e3, C8=10e-9, VB=1.06, RIN=0.0),
    # rev A: CMOS rail-to-rail comparator, mid-rail bias, 10x higher impedance, 1k input resistor
    'board': dict(R7=68e3, C7=10e-9, R8=680e3, C8=1e-9, VB=1.65, RIN=1e3),
}

# (net, Rsrc ohm, Vpp open-circuit, hum ratio, hysteresis V) -- exactly the DESIGN.md table
CASES = [
    ('draft', 100,  5.0, 0.0, 0.060),
    ('draft', 100,  6.0, 0.0, 0.060),
    ('board', 10e3, 0.05, 0.0, 0.010),
    ('board', 10e3, 0.2, 0.0, 0.010),
    ('board', 10e3, 0.2, 4.0, 0.010),
    ('board', 10e3, 1.0, 4.0, 0.040),
    ('board', 10e3, 5.0, 0.2, 0.040),
    ('board', 10e3, 6.0, 0.0, 0.040),
    ('board', 100,  0.2, 4.0, 0.010),
    ('board', 100,  5.0, 0.2, 0.040),
    ('board', 100,  6.0, 0.0, 0.010),
    ('board', 100,  6.0, 0.0, 0.040),
    # TLV7031 worst-case input offset (8 mV max), both signs; the sixth field overrides the +3 mV default
    ('board', 10e3, 0.05, 0.0, 0.010, +0.008),
    ('board', 10e3, 0.05, 0.0, 0.010, -0.008),
    ('board', 10e3, 0.2, 4.0, 0.010, +0.008),
    ('board', 10e3, 0.2, 4.0, 0.010, -0.008),
    ('board', 100,  6.0, 0.0, 0.040, -0.008),
]

if __name__ == '__main__':
    raw, fr, pp = load(sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), '..', '..', 'host', 'tests', 'data', 'zx48k-save-test.wav'))
    print('net   Rsrc   Vpp   hum  hyst  offs  | decode | B min..max V | clamp mA | ADC pin V   | DC shift mV')
    for net, rsrc, vpp, hum, hy, *rest in CASES:
        off = rest[0] if rest else 0.003
        r = simulate(raw, fr, pp, NETS[net], vpp, hum, hy, rsrc, offset=off)
        print(f"{net:5s} {rsrc:6.0f} {vpp:5.2f} {hum:4.1f} {hy*1e3:4.0f}mV {off*1e3:+3.0f}mV | {'OK  ' if ok(r['blocks']) else 'FAIL'}   |"
              f" {r['bmin']:5.2f}..{r['bmax']:5.2f}  | {r['imax']*1e3:7.3f}  | {r['gmin']:5.2f}..{r['gmax']:4.2f} | {r['shift']*1e3:7.1f}")
