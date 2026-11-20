# Tape-port modem board, rev C: ESP32-S3 SuperMini carrier

A 53 x 26 mm, 2-layer carrier for an **ESP32-S3 SuperMini** dev board, with
the two 3.5 mm jacks (EAR, MIC), the MIC input stage, the EAR output and a
PLAY button. JLCPCB assembles everything except the SuperMini, which is
soldered on by hand. Overview and wiring summary: [`docs/hardware.md`](../docs/hardware.md).

## Rev C (current) — the jack pinout fix

Rev C is rev B with one correction: in both jacks the **signal moves to pin 5 (tip)** and **pin 2 (ring) becomes ground**. Pin 1 (sleeve) stays ground; pins 3 and 4 (switch contacts) stay unconnected. Everything else (parts, placement, size, BOM and placement files) is unchanged; the board is re-routed around the two new connections.

- **Why:** the PJ-307 that JLCPCB fits (HOOYA, LCSC C2939173) has tip = pin 5, ring = pin 2, sleeve = pin 1. Rev B was wired from a measurement of a different maker's PJ-307 (tip = 2, ring = 5): "PJ-307" names a body style, not a fixed pinout. Found on the first rev B boards, 2026-11-13.
- **Ring = ground, not unconnected:** a mono plug's long sleeve touches both the ring and sleeve contacts, so the ring must not carry the signal.
- **Checks (2026-11-20):** netlist check OK, ERC 0, DRC 0 errors and 0 unconnected with schematic parity (6 silk-at-edge warnings from the jack outlines), JLCPCB placement check worst 0.16 mm (jacks 0.00 mm). **Not built yet.**
- The project's PJ-307 symbol labels pin 5 "T" and pin 2 "R" (the switch contacts: 3 "RN", 4 "TN", by position; their pairing isn't measured, and they're unused).

**Rev B boards** (the first batch) have the signal on the ring contact and ground on the tip. Workarounds, no board cuts: solder a mono cable to the underside joints (core to pin 2, shield to pin 1) and never plug anything into the jacks; or use a tip/ring swap adapter or cable (board-side ring to Spectrum-side tip). See `docs/hardware.md`.

## The board

The design follows a hardware review: cheap, small, and easy to build and rework by hand.

| Area | Choice | Why |
|---|---|---|
| ESP32 | **ESP32-S3 SuperMini dev board, hand-soldered** (USB-C, 3.3 V regulator, BOOT/RESET on the dev board) | Every ESP32 module JLCPCB stocks is "Standard PCBA only" (X-ray); a dev board avoids that fee and about 15 parts |
| Assembly | **Economic PCBA** for the 22 SMD parts plus the two PJ-307 jacks (wave soldered by JLCPCB); you solder only the SuperMini | Cheaper; the jacks cost the same at JLCPCB as locally |
| Passives | **0805** everywhere | Easy to rework by hand |
| Jacks | **Through-hole PJ-307** stereo jacks (HOOYA, LCSC C2939173, Extended part; expect a through-hole assembly fee on the quote). Footprint from the HOOYA data (matches JLCPCB's footprint to 0.00 mm, all pin numbers agree) and the PJ-307 drawing (0.8 x 1.7 mm slots, 5 x 1.2 mm pegs) | Sturdy, cheap. Optional check before ordering: lay a jack on the 1:1 print `kicad/zx-modem-1to1-check.pdf` (print at 100 %) |
| Hysteresis | **Fixed R11 = 1.5 k**: 3.3 V x 1.5/471.5 = **10.5 mV** | The recommended setting (see "MIC input"); to change it, swap the 0805 |
| LEDs | none on the carrier: the SuperMini has a power LED and an RGB LED on GPIO48 | Fewer parts |
| Size | **53 x 26 mm**, no mounting holes | Small; the jacks hold it in place |

**SuperMini pin use** (pinout per espboards.dev; footprint `kicad/zx-modem.pretty/ESP32-S3-SuperMini`):

| SuperMini pin | Use |
|---|---|
| GPIO4 | RX (comparator output) |
| GPIO5 | ADC tap (ADC1, usable while Wi-Fi is on) |
| GPIO6 | TX to EAR (RMT) |
| GPIO7 | PLAY button |
| 3V3, GND | supply for our parts (from the SuperMini's regulator) |

**SuperMini size (confirmed by measurement, 2026-11-02):** 22.52 x 18 mm, standard 2.54 mm pitch, 9 pins per side, rows 15.24 mm (0.6 in) apart. The footprint uses 1.5 mm pads on 1.0 mm holes, so the pins nearest the USB end (1.1 mm from it) keep 0.3 mm copper clearance from the board edge.

**Layout:** SuperMini on the left with USB-C flush to the left edge; no copper under its antenna end (both layers), and no top-side traces or vias under it (it is soldered flat, and its underside has bare pads). PJ-307 jacks on the right edge (openings out, pin 1 nearest the edge), PLAY button bottom middle. All nets routed, GND pour on both layers.

**Order files** (`fab/`): `zx-modem-gerbers.zip`, `zx-modem-bom.csv` + `zx-modem-cpl.csv` (JLCPCB Economic PCBA, 24 parts incl. both jacks), `zx-modem-hand-solder.csv` (the SuperMini only). Before ordering, check JLCPCB's assembly preview (every part on its pads, the jacks the right way round) and live stock for every line.

## 1. Block diagram

```
 SuperMini (USB-C power, 3V3 regulator) ── 3V3 ──┬── TLV7031 (U4) + C10
                                                 ├── bias R9/R10/C9 -> VBIAS 1.65 V
                                                 └── clamps D1, D2; PLAY pull-up R18

 Spectrum EAR <── J2 tip <── R5 220R <──┬── GPIO6 (TX, RMT)
                                        └── D2 clamp to GND/3V3
 Spectrum MIC ──> J3 tip ─ R20 1k ─ C7 10n ─A─ C8 1n ─B─┬─ R17 10k ─> U4 IN- ─> OUT ─> GPIO4 (RX edge ISR)
                                  R7 68k│    R8 680k│   ├─ R14 10k ─> GPIO5 (ADC) + C11 100p
                                      VBIAS      VBIAS  └─ D1 clamp to GND/3V3
                VBIAS ─> R11 1.5k ─> U4 IN+ <─ R12 470k <─ OUT
 SW3 PLAY ─> R19 1k ─> GPIO7 (R18 10k pull-up, C12 100n)
 J2/J3: sleeve (pin 1) and ring (pin 2) to GND; switch contacts (3, 4) unconnected
```

## 2. KiCad flow

All in [kicad/](kicad/), KiCad 10. `KPY` = KiCad's own Python (`"C:/Program Files/KiCad/10.0/bin/python.exe"` on Windows).

1. `python -I hardware/kicad/gen_schematic.py`: the schematic from the PARTS table in that script (the single source of truth).
2. `kicad-cli sch export netlist ...`, then `python -I hardware/kicad/check_netlist.py`: KiCad's netlist must match PARTS pin for pin (63 connections, 15 nets).
3. `KPY -I hardware/kicad/build_pcb.py`: board outline, footprints, nets, placement, net classes, antenna keep-out, labels.
4. `KPY -I hardware/kicad/route_pcb.py`: Freerouting 2.5.0 (needs Java 25; set `FREEROUTING_JAR`), then GND pours on both layers and stitching vias. Freerouting varies a little between runs; the committed `.kicad_pcb` is the checked result.
5. `kicad-cli pcb drc --schematic-parity`: 0 errors, 0 unconnected. Remaining warnings: silkscreen at the jack edge (intended).
6. `python -I hardware/kicad/make_fab.py`: the Gerber/drill zip, the JLCPCB BOM and CPL, and the hand-solder list. The CPL is corrected to JLCPCB's own footprints: `KPY -I hardware/kicad/jlc_fit.py` fits each part's EasyEDA footprint onto ours and writes `jlc_corrections.json` (rotation and origin offset per LCSC part). The EasyEDA footprint data isn't in the repository; `jlc_fit.py` explains where to download it into `kicad/easyeda/`.
7. `KPY -I hardware/kicad/jlc_fit.py --check`: places JLCPCB's footprints exactly as the CPL says and measures every pad against our copper (current worst: 0.16 mm).

## 3. Sections and calculations

### What the 48K puts out and accepts (checked; resistor values partly unverified)
- **The pin-28 voltages are measured,** from the World of Spectrum 48K reference.
  - The Spectrum's MIC, EAR and speaker all hang off **ULA pin 28**.
  - Issue 3 levels: bit4/bit3 = 00 → **0.34 V**, 01 → **0.66 V**, 10 → 3.56 V, 11 → 3.70 V. Issue 2 is about 0.05 V higher.
  - The EAR input threshold is **0.70 V**, with no hysteresis.
  - The pin connects to the sockets through capacitors and resistors only.
- **SAVE (ROM SA-BYTES) toggles only bit 3**, as the red/cyan border shows. So pin 28 swings just **0.34 ↔ 0.66 V = ~0.32 V p-p**.
  - A passive network can't make more than that at the MIC socket. So **the open-circuit MIC level is at most ~0.35 V p-p.**
  - The "4–5 V p-p unloaded / 1 V p-p loaded" figure found online contradicts this. It most likely describes the EAR/beeper path (bit 4, ~3.2 V swing) or a 128K/+2-type machine.
  - A PC line-in recording of a real 48K showed about 0.5 V p-p (uncalibrated), the same order of magnitude, with clean edges and ROM timings within 0.3 %.
- **MIC source impedance: ~10 kΩ (estimate).** A forum description puts a 10k series resistor in the MIC path, which couldn't be checked against a schematic. That's why the input has **|Z| ≈ 70 kΩ** at 1 kHz: R20 1k + C7 (16 kΩ reactance) + R7 68k. The jack then keeps **≈ 87%** of the open-circuit level, i.e. ~0.28 V p-p.
- **EAR input impedance: ≈ 680 Ω + Z(pin 28) ≈ 1.7–5.7 kΩ (estimate).** A 680 Ω resistor plus a capacitor sit between the EAR socket and pin 28; the pin-28 node impedance is unknown, assumed here to be 1–5 kΩ.

### a) EAR output (R5, R6, D2)
- **R5 = 220 Ω.** The voltage at the socket = 3.3 V · Z_EAR/(R5 + Z_EAR): **2.9 V p-p** at Z_EAR = 1.7 kΩ, 3.2 V p-p at 5.7 kΩ.
- *Why this works:* LOAD only needs pin 28 to cross 0.70 V, from a rest level of 0.66 V (bit 3 = 1 during LD-BYTES), so the margin is large even at the low-impedance estimate.
- **Protection:** if the Spectrum beeps, it drives up to ~3.7 V through its 680 Ω. The current into our side is ≤ 3.7 V/(680 + 220) ≈ **4 mA**, and D2 (BAT54S) diverts it to the rails before the ESP32's own ESD diodes conduct. The GPIO's own current into the EAR load is ≤ 3.3 V/(220 + 1.7k) ≈ 1.7 mA.
- **R6 (not fitted)** from the EAR signal to GND stays available as an attenuator option.

### b) MIC input: input resistor, passive 2nd-order high-pass, CMOS comparator
Chain: J3 tip → **R20 1k** → **C7 10 nF** → A, **R7 68k → VBIAS** → **C8 1 nF** → B, **R8 680k → VBIAS** → **R17 10k** → U4 IN-.

**Cutoff:** 1/(2π·68k·10n) = 1/(2π·680k·1n) = **234 Hz** per pole (false edges start at ~390 Hz).

| Frequency | Attenuation |
|---|---|
| 50 Hz hum | about −27 dB |
| 807 Hz pilot | −0.7 dB |
| 1023 Hz bit 1 | −0.4 dB |
| 2045 Hz bit 0 | −0.1 dB |

**Why it's built this way:**
1. **High impedance** (68k/680k with 10n/1n), so the Spectrum's ~10k source isn't loaded. That needs a **CMOS comparator**: the TLV7031's bias current is 2 pA max, so 680k causes about 1.4 µV of offset (an LM393's up to 250 nA × 68k would already be a 17 mV error, bigger than the hysteresis).
2. **Rail-to-rail input lets VBIAS sit at mid-rail, 1.65 V** (R9 = R10 = 10k, with C9 10 µF): the most headroom before the clamps (±1.9 V), and symmetric hysteresis with the push-pull output.
3. **R20 1k sets a minimum source impedance.** With a 0 Ω source and a sharp 6 V edge, the clamp current is limited to ≤ 6 mA, for about 1 µs (1k × 0.9 nF).
4. **Clamp D1 (BAT54S) at node B, with R17 10k / R14 10k in front of the comparator and the ADC pin.** That keeps any current into IC pins in the µA range.
5. **DC-restorer effect:** clamp current recharges C8, shifting node B's centre away from VBIAS. A low-impedance first draft (6.8k/68k, 1.06 V bias) shifted by **0.55 V** and **failed at 6 V p-p**; this network keeps the clamp current ≤ 0.11 mA and the shift ≤ 0.13 V, so it decodes up to 6 V p-p.

**Hysteresis:**
- IN+ connects to VBIAS through **R11 1.5k**, with **R12 470k** feedback from the push-pull output: width = 3.3 V · 1.5k/(1.5k + 470k) = **10.5 mV**, centred on VBIAS.
- That suits the real 48K (~0.3 V p-p at the jack). For loud or hummy sources, R11 = 6.2k gives about 43 mV.
- *Why this works:* the threshold is VBIAS itself, which is exactly the signal's AC centre, so only the hysteresis width needs choosing. The TLV7031's Vos is 8 mV max; the simulation's base cases use +3 mV, and extra cases run the ±8 mV worst case.

**Comparator:** TLV7031DBVR (C2869832, Extended), SOT-23-5, pinout **1 OUT, 2 V-, 3 IN+, 4 IN-, 5 V+** (KiCad's `Comparator:TLV7031DBV` symbol).
- Supply 3V3 with C10 100 nF; input range 0 … V+ (rail-to-rail).
- Its 3 µs propagation delay is < 2% of the shortest half-pulse (244 µs) and the same on every edge, so it cancels out in the pulse lengths.
- **The push-pull output is 0–3.3 V, so GPIO4 can never exceed its rails.**

**Simulation** (`python -I hardware/sim/frontend_sim.py`, on the real 48K recording in `host/tests/data/`):
- **Model:** backward-Euler integration of the exact network, a BAT54 exponential diode (≈0.24 V at 0.1 mA, 0.32 V at 1 mA), the source impedance, 50 Hz hum added at the source, comparator offset +3 mV (±8 mV in the worst-case rows), 1 mV rms noise, and a ROM-style decoder.
- **Pass criterion:** "OK" = both blocks of the recording decode (19-byte header + 57-byte data, both checksums good).
- The table lists **exactly** the script's cases, in order. "draft" is the low-impedance first draft, for comparison; "board" is this board's network.

| Net | Rsrc | Vpp (open circuit) | Hum | Hyst | Decode | Node B min..max | Clamp peak | ADC pin | Centre shift |
|---|---|---|---|---|---|---|---|---|---|
| draft | 100 Ω | 5.0 | 0 | 60 mV | OK | −0.31..3.60 V | 0.84 mA | −0.31..3.57 | 519 mV |
| draft | 100 Ω | 6.0 | 0 | 60 mV | **FAIL** | −0.32..3.61 V | 1.13 mA | −0.32..3.60 | 548 mV |
| board | 10 kΩ | 0.05 | 0 | 10 mV | OK | 1.62..1.67 | 0 | 1.62..1.67 | 0 |
| board | 10 kΩ | 0.2 | 0 | 10 mV | OK | 1.53..1.74 | 0 | 1.53..1.74 | 0 |
| board | 10 kΩ | 0.2 | 4× | 10 mV | OK | 1.53..1.75 | 0 | 1.53..1.75 | 0 |
| board | 10 kΩ | 1.0 | 4× | 40 mV | OK | 1.06..2.15 | 0 | 1.07..2.15 | 0 |
| board | 10 kΩ | 5.0 | 0.2× | 40 mV | OK | −0.21..3.49 | 0.04 mA | −0.20..3.48 | 88 mV |
| board | 10 kΩ | 6.0 | 0 | 40 mV | OK | −0.22..3.51 | 0.06 mA | −0.21..3.51 | 101 mV |
| board | 100 Ω | 0.2 | 4× | 10 mV | OK | 1.52..1.77 | 0 | 1.52..1.77 | 0 |
| board | 100 Ω | 5.0 | 0.2× | 40 mV | OK | −0.23..3.53 | 0.08 mA | −0.22..3.52 | 115 mV |
| board | 100 Ω | 6.0 | 0 | 10 mV | OK | −0.24..3.53 | 0.11 mA | −0.24..3.53 | 134 mV |
| board | 100 Ω | 6.0 | 0 | 40 mV | OK | −0.24..3.53 | 0.11 mA | −0.24..3.53 | 134 mV |
| board, offset +8 mV | 10 kΩ | 0.05 | 0 | 10 mV | OK | 1.62..1.67 | 0 | 1.62..1.67 | 0 |
| board, offset −8 mV | 10 kΩ | 0.05 | 0 | 10 mV | **FAIL** | 1.62..1.67 | 0 | 1.62..1.67 | 0 |
| board, offset +8 mV | 10 kΩ | 0.2 | 4× | 10 mV | OK | 1.53..1.75 | 0 | 1.53..1.75 | 0 |
| board, offset −8 mV | 10 kΩ | 0.2 | 4× | 10 mV | OK | 1.53..1.75 | 0 | 1.53..1.75 | 0 |
| board, offset −8 mV | 100 Ω | 6.0 | 0 | 40 mV | OK | −0.24..3.53 | 0.11 mA | −0.24..3.53 | 134 mV |

- **Worst-case offset (TLV7031, 8 mV max):** the whole 0.2–6 V p-p range still passes at ±8 mV. Only the 0.05 V p-p margin case fails at −8 mV, which is 4× below the 0.2 V p-p requirement and ~6× below the real 48K level.
- **Hum at large signals:** 4× hum is only run at ≤ 1 V p-p; the 5 V cases use 0.2× (5 + 1 = 6 V total, the safety limit).
- **Margin:** it decodes down to **0.05 V p-p**, 4× below the 0.2 V p-p requirement, which matters because the real 48K level is only ~0.3 V p-p.

**Safety against the requirements (up to 6 V p-p):**
- **Comparator IN-:** node B stays within −0.24 … 3.53 V in all simulated cases, inside −0.3 … 3.6 V; IN- is behind R17 10k, so pin current is < 30 µA even if B overshoots. Not simulated: a 0 Ω source with ns edges could pull B to about −0.38 V for ~1 µs (6 mA through D1); at IN- that's attenuated further and the current stays < 10 µA.
- **GPIO5 (ADC):** −0.24 … 3.53 V in the simulation, behind R14 10k + C11 100 pF (τ = 1 µs), which also smooths the worst-case spike.
- **GPIO4:** driven by the 3V3-supplied push-pull output, so always 0 … 3.3 V.
- **Clamp current:** ≤ 0.11 mA simulated, ≤ 6 mA in the hand-calculated worst-case spike. The BAT54S is rated 200 mA.

### c) ADC tap ("built-in scope")
- Node B → R14 10k → GPIO5, with C11 100 pF to GND at the pin. GPIO5 sees the filtered signal centred on 1.65 V.
- **ADC range:** 12 dB attenuation (0 … ~3.1 V) for large signals, or a lower attenuation for the real ~0.3 V p-p.
- **Accuracy:** node B's source impedance is high (680k ∥ the C8 path); C11 acts as the charge reservoir for the ADC's sample capacitor. For level and waveform display at ≤ 20 kSa/s expect a few-% error: fine for a level meter or a fallback software decoder, not a precision measurement.

### d) PLAY button (SW3, R18, R19, C12)
- GPIO7 → R18 10k pull-up to 3V3, C12 100 nF to GND, and the switch connects GPIO7 to GND **through R19 1k**.
- Pressed: 3.3 V · 1k/11k = 0.30 V, well below the S3's V_IL of 0.25·VDD = 0.83 V. τ_press ≈ 0.09 ms, τ_release = 1 ms.
- *Why this works:* the RC swallows contact bounce, and R19 stops the switch dumping C12's charge instantly through its contacts.
- The firmware acts when the button is released: a short press sends the menu, 2–5 s sends the tape test, 5 s or more forgets the saved Wi-Fi networks.

### e) Jacks (J2 EAR, J3 MIC)
- **HOOYA PJ-307** (LCSC C2939173), 3.5 mm stereo, through-hole, fitted by JLCPCB.
- **Pinout of this part:** 1 sleeve, 5 tip, 2 ring; 3 and 4 are switch contacts that touch the tip and ring springs only when no plug is in.
- **Wiring:** tip = signal; sleeve and ring = GND (a mono plug's sleeve bridges ring and sleeve); switch contacts unconnected, so no switch can short the signal when the jack is empty.

## 4. Nets

| Net | Connects |
|---|---|
| 3V3 | SuperMini 3V3 (U1 pin 12), R18, R9, U4 V+ (pin 5), C10, D1 pin 2, D2 pin 2 |
| GND | SuperMini GND (U1 pin 11), J2 pins 1+2, J3 pins 1+2, U4 V- (pin 2), C9, C10, C11, C12, R10, R6 (not fitted), SW3, D1 pin 1, D2 pin 1 |
| TX_GPIO | U1 GPIO6, D2 pin 3, R5 |
| EAR_OUT | R5, R6 (not fitted), J2 pin 5 (tip) |
| MIC_IN | J3 pin 5 (tip), R20 |
| MIC_R | R20, C7 |
| HP_A | C7, R7, C8 |
| HP_B | C8, R8, D1 pin 3, R17, R14 |
| CMP_IN | R17, U4 IN- (pin 4) |
| VBIAS | R9, R10, C9, R7, R8, R11 |
| CMP_REF | R11, R12, U4 IN+ (pin 3) |
| RX | U4 OUT (pin 1), R12, U1 GPIO4 |
| ADC_TAP | R14, C11, U1 GPIO5 |
| PLAY | U1 GPIO7, R18, C12, R19 |
| BTN_PLAY_SW | R19, SW3 (its other side to GND) |
| (unconnected) | J2/J3 pins 3 and 4, the SuperMini's other pins |

## 5. Parts and fees
- **Extended parts:** D1/D2 BAT54S (C47546), U4 TLV7031 (C2869832), J2/J3 PJ-307 (C2939173). SW3 TS-1187A (C318884): class not shown on its page.
- **Basic-type parts:** the 0805 resistors and capacitors (class not checked one by one).
- **Fees:** at the commonly quoted ~$3 setup fee per Extended part type (a third-party figure, not verified), about $9–12 per order, plus the through-hole (wave soldering) fee for the jacks.
- **Cheaper option considered:** BAT54S has no verified Basic equivalent, and a 1N4148W clamp at ~0.6 V would break the −0.3 V input limit, so it stays.

## 6. Still unverified
1. The 48K MIC series resistor (~10k) and the pin-28 node impedance. Only the pin-28 voltages are verified. The design tolerates 0.05–6 V p-p and a source impedance of 100 Ω–10 kΩ, so these mostly affect the expected level, not function.
2. The exact MIC level at the board. The ADC tap can measure it.
3. Basic/Extended classes and live stock, at order time.
4. Rev C itself: not built yet.
