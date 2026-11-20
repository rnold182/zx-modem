# Tape-port modem board, rev B: ESP32-S3 SuperMini carrier

## Rev B (current) — what changed and why

Rev B follows a hardware review: make it cheaper and easier to build.

| Change | Rev A | Rev B | Why |
|---|---|---|---|
| ESP32 | ESP32-S3-WROOM-1 module on the board, plus USB-C, USBLC6 ESD, AMS1117, EN/BOOT/RESET parts | **ESP32-S3 SuperMini dev board, hand-soldered** (USB-C, 3.3 V regulator, BOOT/RESET on the dev board) | Every ESP32 module JLCPCB stocks is "Standard PCBA only" (X-ray); the dev board avoids that fee and ~15 parts |
| Assembly | Standard PCBA (module) | **Economic PCBA** for the 22 SMD parts plus the two PJ-307 jacks (C2939173, wave soldered by JLCPCB); you solder only the SuperMini | Cheaper; the jacks cost the same at JLCPCB as locally |
| Passives | 0402 | **0805** everywhere | Easier to rework by hand |
| Jacks | SMD PJ-320D-4A | **Through-hole PJ-307** stereo jack. Pinout **measured on the local jacks: 1 sleeve, 2 tip, 5 ring (right); 3 and 4 are switch contacts that carry nothing with a plug in.** Board: 2 = signal, 1 and 5 = GND, 3 and 4 unconnected (so no switch can short the signal when no plug is in). **Assembled by JLCPCB** (HOOYA PJ-307, LCSC C2939173, Extended part, through-hole by wave soldering, so expect a THT assembly fee on the quote). Footprint from the HOOYA PJ-307 data (matches JLCPCB's footprint to 0.00 mm, all pin numbers agree) and the PJ-307 datasheet drawing (0.8 x 1.7 mm slots, 5 x 1.2 mm pegs) | Two were on hand; the Lumberg 1503 07 first chosen looks discontinued. Optional check before ordering: lay a jack on the 1:1 print `kicad/zx-modem-1to1-check.pdf` (print at 100 %) |
| Hysteresis | 3314J trimmer (about EUR 2.80) | **Fixed R11 = 1.5 k** -> 3.3 V x 1.5/471.5 = **10.5 mV** (the recommended setting; simulation passes at 10 mV incl. +/-8 mV comparator offset) | Cheapest; to change it, swap the 0805 |
| LEDs | power + status LED | none: the SuperMini has a power LED and an RGB LED on GP48 | Fewer parts |
| Test header J4 | 7 probe holes | removed | Smaller board |
| Board | 68 x 50 mm, 3 M3 holes | **53 x 26 mm**, no holes | ~60 % less area |

**SuperMini pin use** (pinout per espboards.dev, USB-C at the top; footprint `kicad/zx-modem.pretty/ESP32-S3-SuperMini`):

| SuperMini pin | Use |
|---|---|
| GP4 | RX (comparator output) |
| GP5 | ADC tap (ADC1) |
| GP6 | TX to EAR |
| GP7 | PLAY button |
| 3V3, GND | supply for our parts (from the SuperMini's regulator) |

**SuperMini size (confirmed by measurement, 2026-11-02):** 22.52 x 18 mm, standard 2.54 mm pitch, 9 pins per side, rows 15.24 mm (0.6 in) apart. The footprint uses 1.5 mm pads on 1.0 mm holes, so the pins nearest the USB end (1.1 mm from it) keep 0.3 mm copper clearance from the board edge.

**Layout:** SuperMini on the left with USB-C flush to the left edge; no copper under its antenna end (both layers), and no top-side traces or vias under it (it is soldered flat, and its underside has bare pads). PJ-307 jacks on the right edge (openings out, pin 1 nearest the edge), PLAY button bottom middle. All nets routed, GND pour on both layers.

**Known issue on the rev B boards (found 2026-11-13):** the PJ-307 that JLCPCB fits (HOOYA, C2939173) has **tip = pin 5, ring = pin 2**, sleeve = pin 1, the other way round from the local jacks the pinout was measured on. So rev B has the signal on the ring contact and GND on the tip. Workarounds, no board cuts: solder a mono cable to the underside joints (core to pin 2, shield to pin 1) and never plug anything into the jacks; or use a tip/ring swap adapter or cable. Rev C fix: swap the nets of pins 2 and 5.

**Order files** (`fab/`): `zx-modem-gerbers.zip`, `zx-modem-bom.csv` + `zx-modem-cpl.csv` (JLCPCB Economic PCBA, 24 parts incl. both jacks), `zx-modem-hand-solder.csv` (SuperMini only).

The front-end analysis below (section 3d onward: 48K levels, filter, clamp, simulation) still applies to rev B unchanged, except that the trimmer is now the fixed R11. Rev A's module, USB and power sections are history.

## Rev A (history)

**KiCad flow** (all in [kicad/](kicad/), KiCad 10; `KPY` = `"C:/Program Files/KiCad/10.0/bin/python.exe"`):
1. `python -I hardware/kicad/gen_schematic.py`: schematic from the PARTS table (the single source of truth).
2. `kicad-cli sch export netlist ...` then `python -I hardware/kicad/check_netlist.py`: KiCad's netlist must match PARTS pin for pin (rev B: 63 connections, 15 nets).
3. `KPY -I hardware/kicad/build_pcb.py`: board outline, footprints, nets, placement, net classes, antenna keep-out, labels.
4. `KPY -I hardware/kicad/route_pcb.py`: Freerouting 2.5.0 (needs Java 25; set `FREEROUTING_JAR`), GND pours on both layers + stitching vias. Freerouting varies a little between runs; the committed `.kicad_pcb` is the reviewed result.
5. `kicad-cli pcb drc`: 0 errors, 0 unconnected. Remaining warnings: silkscreen at the connector edge (intended) and the module footprint differing from the library (its 0.2 mm thermal vias were enlarged to JLCPCB's 0.3 mm minimum).
6. `python -I hardware/kicad/make_fab.py`: Gerber/drill zip, JLCPCB BOM and CPL. The CPL is corrected to JLCPCB's own footprints: `KPY -I hardware/kicad/jlc_fit.py` fits each part's EasyEDA footprint (cached in `kicad/easyeda/`) onto ours and writes `jlc_corrections.json` (rotation + origin offset per LCSC part; LED pads are matched by function, K/A, because JLCPCB numbers them the other way round).
7. `KPY -I hardware/kicad/jlc_fit.py --check`: places JLCPCB's footprints exactly as the CPL says and measures every pad against our copper. Current result: worst 0.25 mm (jack pad drawing difference; its pegs land within 0.1 mm), module signal pins within 0.02 mm, LED polarity correct. The uncorrected KiCad CPL scored 7.3 mm (jacks), 3.7 mm (module), 1.6 mm (USB-C).

**Layout:** 68 × 50 mm, 2 layers. Module antenna overhangs the top edge (all pads on the board), with a no-trace/no-via strip under its antenna end so the ground edge there stays solid. MIC/EAR jacks and USB-C on the bottom edge; front end beside the module's signal pins; buttons (labelled BOOT/RESET/PLAY) and test holes on the right. Power nets 0.5 mm, signals 0.25 mm.

**Before ordering:** JLCPCB's preview should now show every part on its pads; still look at U1, J1, J2/J3 and the LEDs' cathode marks. Re-check live stock for every line.

**Final check (2026-11-02), all re-run from the files on disk:** schematic regenerates identically; ERC 0 errors / 0 warnings; netlist matches the design table (136 connections, 28 nets); board DRC 0 errors, 0 unconnected, **0 schematic-parity issues** (warnings only: silkscreen at the connector edge, enlarged module thermal vias); JLCPCB placement check worst 0.25 mm on pads (module signal pins 0.02 mm), LED polarity correct; BOM/CPL = the 45 parts of the design table (J4, R6 not placed by design); front-end simulation matches the table above; host build + tests pass.

**Review notes (not blocking, for the human check):**
- **C1 (10 µF on VBUS, regulator input) is 11.7 mm from U2's VIN pin.** Usual practice is next to VIN. The output caps (C2/C3) are 3.5–4.4 mm from the VO tab, which is what keeps the AMS1117 stable, so this normally works, but moving C1 beside VIN is the clean fix (needs a re-route).
- **AMS1117 with ceramic output caps:** the datasheet asks for ≥ 22 µF; we have 22 µF + 100 nF at the regulator and again at the module. Common practice on ESP32 boards, but its stability with low-ESR ceramics is a known AMS1117 debate.
- **RV1:** start at ~0.5 kΩ (≈ 10 mV hysteresis) for a real 48K; see §3d.
- **J4** is unpopulated probe holes; **R6** is a do-not-fit EAR attenuator option.

**Assembly type:** every ESP32 module JLCPCB stocks (S3-WROOM-1 all variants incl. 1U, S3-MINI-1, C3-MINI-1) is "Standard Only" (X-ray inspection required); only the bare ESP32-S3 chip is Economic. So with U1 fitted by JLCPCB the order must be Standard PCBA.

**Build:** full JLCPCB SMT assembly. Every fitted part is a JLCPCB-library SMD part, and nothing is hand-soldered (J4 is unpopulated plated holes, see §3f).

**Changes since the first draft:**
- LM393 → **TLV7031** (CMOS, rail-to-rail input, push-pull output), with mid-rail bias. The first pick, LMC7211, was swapped at the KiCad stage because its SOT-23-5 pinout couldn't be verified; the TLV7031's comes from KiCad's library.
- MIC input impedance raised 10×, plus an input resistor R20.
- SMD trimpot; SMD PJ-320D-4A jacks (Hroparts C95562, matching KiCad's footprint).
- TX R5 1k → 220 Ω.
- Separate PLAY button SW3 on GPIO8.
- The simulation now models the real diode clamp and the source impedance.

## 1. Block diagram

```
 USB-C (J1) ──VBUS──┬──────────────► AMS1117-3.3 (U2) ──► 3V3 ──┬── ESP32-S3-WROOM-1 (U1)
   │ D+/D-          │                                           ├── TLV7031 (U4), bias, LEDs
   │                └─ USBLC6-2SC6 (U3) ESD on VBUS, D+, D-      └── test holes J4 (DNP)
   └── D-/D+ ────────────────────────────────► GPIO19/GPIO20 (native USB-Serial/JTAG)

 Spectrum EAR ◄── J2 tip ◄── R5 220R ◄── D2 clamp ◄── GPIO6  (TX, RMT)
 Spectrum MIC ──► J3 tip ─ R20 1k ─ C7 10n ─A─ C8 1n ─B─┬─ R17 10k ─► U4 IN- ─► OUT ─► GPIO4 (RX edge ISR)
                                  R7 68k│     R8 680k│  ├─ R14 10k ─► GPIO5 (ADC1_CH4) + C11 100p
                                      VBIAS       VBIAS  └─ D1 clamp to GND/3V3
                    VBIAS (1.65 V) ─► R11 1k + RV1 5k ─► U4 IN+ ◄─ R12 470k ◄─ OUT
 SW1 BOOT ─► GPIO0 (flashing only)        SW2 RESET ─► EN        SW3 PLAY ─► GPIO8
 LED1 red: 3V3 power                       LED2 red: GPIO7 status
```

## 2. Module and pin assignment

**Module: ESP32-S3-WROOM-1-N8R2** (C2913204). The pin map also works with the **N16R8** (C2913202).

| GPIO | Use | Why this pin |
|---|---|---|
| 0 | **BOOT, flashing only** (SW1 to GND, R4 10k pull-up) | Strapping pin: low at reset = download mode. No longer the user button, so PLAY can never accidentally enter the bootloader. |
| 4 | RX: comparator output (push-pull, 0–3.3 V) | Any GPIO can take the edge ISR. It's on ADC1 too, for debugging. |
| 5 | ADC tap of the filtered MIC signal | **ADC1** (CH4): ADC2 is unusable while Wi-Fi is on. |
| 6 | TX to EAR | RMT can drive any pin through the GPIO matrix. 6 isn't a strapping pin. |
| 7 | Status LED (red) | Free, not a strapping pin. |
| **8** | **PLAY button SW3** (new): play the bootstrap tape; a 5 s long press erases Wi-Fi | Free, non-strapping, not a USB/JTAG/PSRAM pin. The RC debounce is in §3h. |
| 19 / 20 | USB D- / D+ | Fixed USB-Serial-JTAG pins. |
| 43 / 44 | UART0 TX/RX to the J4 test holes | Console fallback. |
| 3, 45, 46 | **Unconnected** | Strapping pins (JTAG source, VDD_SPI voltage, download mode). The internal pull-downs give the right defaults. |
| 35–37 | Not used | Octal PSRAM on the R8 variants (keeps the N16R8 fallback possible). |
| 39–42 | Not used | Kept free for JTAG. |

Spare pins: 1, 2, 9–18, 21, 38, 47, 48.

## 3. Sections and calculations

### What the 48K actually puts out and accepts (checked; resistor values partly unverified)
- **The pin-28 voltages are measured,** from the World of Spectrum 48K reference.
  - The Spectrum's MIC, EAR and speaker all hang off **ULA pin 28**.
  - Issue 3 levels: bit4/bit3 = 00 → **0.34 V**, 01 → **0.66 V**, 10 → 3.56 V, 11 → 3.70 V. Issue 2 is about 0.05 V higher.
  - The EAR input threshold is **0.70 V**, with no hysteresis.
  - The pin connects to the sockets through capacitors and resistors only.
- **SAVE (ROM SA-BYTES) toggles only bit 3**, as the red/cyan border shows. So pin 28 swings just **0.34 ↔ 0.66 V = ~0.32 V p-p**.
  - A passive network can't make more than that at the MIC socket. So **the open-circuit MIC level is at most ~0.35 V p-p.**
  - The "4–5 V p-p unloaded / 1 V p-p loaded" figure found on Google contradicts this. It most likely describes the EAR/beeper path (bit 4, ~3.2 V swing) or a 128K/+2-type machine.
  - Our earlier PC estimate (~0.5 V p-p, uncalibrated) is the same order of magnitude.
- **MIC source impedance: ~10 kΩ (estimate).** A forum description puts a 10k series resistor in the MIC path, which I couldn't check against a schematic.
  - That's why the input now has **|Z| ≈ 70 kΩ** at 1 kHz: R20 1k + C7 (16 kΩ reactance) + R7 68k. The jack then keeps **≈ 87%** of the open-circuit level, i.e. ~0.28 V p-p.
  - The old 6.8k input (|Z| ≈ 8 kΩ) would have dropped it to ~44% (~0.14 V p-p).
- **EAR input impedance: ≈ 680 Ω + Z(pin 28) ≈ 1.7–5.7 kΩ (estimate).** The forum gives a 680 Ω resistor plus a capacitor between the EAR socket and pin 28. The pin-28 node impedance is unknown, assumed here to be 1–5 kΩ.

### a) USB-C (J1, U3, R1, R2)
Unchanged: CC1/CC2 → 5.1k to GND (they mark the board as a USB 2.0 sink, so C-to-C chargers turn VBUS on), and USBLC6-2SC6 ESD protection on D+, D- and VBUS. No polyfuse.

### b) 3.3 V supply (U2, C1–C6)
Unchanged: AMS1117-3.3 (Basic, verified).
- Headroom: 4.75 V − ~1.1 V dropout at the ~350 mA Wi-Fi peak = 3.65 V, above the 3.3 V needed.
- Caps: 10 µF on the input, 22 µF + 100 nF on the output, and 22 µF + 100 nF at the module.
- EN: 10k/1 µF delay (τ = 10 ms) plus the RESET button.

### c) TX to EAR (R5, R6, D2)
- **R5 = 220 Ω** (was 1k). The voltage at the socket = 3.3 V · Z_EAR/(R5 + Z_EAR):

  | Z_EAR | R5 = 1k | R5 = 220 Ω |
  |---|---|---|
  | 1.7 kΩ | 2.0 V p-p | **2.9 V p-p** |
  | 5.7 kΩ | 2.8 V p-p | 3.2 V p-p |

- *Why this works:* R5 = 220 Ω meets the ~3 V p-p target even at the low-impedance estimate.
  - In any case LOAD only needs pin 28 to cross 0.70 V, from a rest level of 0.66 V (bit 3 = 1 during LD-BYTES), so the margin is large.
- **Protection:** if the Spectrum beeps, it drives up to ~3.7 V through its 680 Ω. The current into our side is ≤ 3.7 V/(680 + 220) ≈ **4 mA**, and D2 (BAT54S) diverts it to the rails before the module's ESD diodes conduct.
  - The GPIO's own current into the EAR load is ≤ 3.3 V/(220 + 1.7k) ≈ 1.7 mA.
- **R6 (DNP)** from J2 tip to GND stays available as an attenuator option.

### d) RX from MIC: input resistor, passive 2nd-order high-pass, CMOS comparator
Chain: J3 tip → **R20 1k** → **C7 10 nF** → A, **R7 68k → VBIAS** → **C8 1 nF** → B, **R8 680k → VBIAS** → **R17 10k** → U4 IN-.

**Cutoff:** 1/(2π·68k·10n) = 1/(2π·680k·1n) = **234 Hz** per pole, the same corner as before (it sits in the safe window found earlier: false edges start at ~390 Hz).

| Frequency | Attenuation |
|---|---|
| 50 Hz hum | about −27 dB |
| 807 Hz pilot | −0.7 dB |
| 1023 Hz bit 1 | −0.4 dB |
| 2045 Hz bit 0 | −0.1 dB |

**Why the changes:**
1. **The impedance is 10× higher** (68k/680k with 10n/1n) so we don't load the Spectrum's ~10k source (see above).
   - That's only possible with a **CMOS comparator**: the TLV7031's bias current is 2 pA max, so 680k causes about 1.4 µV of offset. The LM393's up to 250 nA × 68k would already have been a 17 mV error, bigger than the smallest hysteresis.
2. **Rail-to-rail input lets VBIAS sit at mid-rail, 1.65 V** (R9 = R10 = 10k, with C9 10 µF).
   - That gives the most headroom before the clamps (±1.9 V), and symmetric hysteresis with the push-pull output.
   - The LM393's input range ends at 1.3–1.8 V at 3.3 V supply, which forced the old 1.06 V bias.
3. **R20 1k sets a minimum source impedance.** With a 0 Ω source and a sharp 6 V edge, the clamp current is limited to ≤ 6 mA, for about 1 µs (1k × 0.9 nF).
4. **Clamp D1 (BAT54S) at node B, with R17 10k / R14 10k in front of the comparator and the ADC pin.** That keeps any current into IC pins in the µA range.
5. **DC-restorer effect (found by the new simulation):** clamp current recharges C8, shifting node B's centre away from VBIAS.
   - The old low-impedance network (6.8k/68k, 1.06 V bias) shifted by **0.55 V** and **failed at 6 V p-p**.
   - The new network keeps the clamp current ≤ 0.11 mA and the shift ≤ 0.13 V, so it decodes up to 6 V p-p.

**Hysteresis:**
- IN+ connects to VBIAS through Rs = **R11 1k + RV1 0–5k** (an SMD trimmer used as a rheostat), with **R12 470k** feedback from the push-pull output.
- Width = 3.3 V · Rs/(Rs + 470k) = **7 mV (RV1 = 0) … 42 mV (RV1 = 5k)**, centred on VBIAS.
- Recommended setting: **~10 mV** (RV1 ≈ 0.5k) for the real 48K (~0.3 V p-p at the jack). 40 mV for loud or hummy sources.
- *Why this works:* the threshold is VBIAS itself, which is exactly the signal's AC centre, so only the hysteresis needs a trimmer. The TLV7031's Vos is 8 mV max; the simulation's base cases use +3 mV, and extra cases run the ±8 mV worst case (see the table).

**Comparator:** TLV7031DBVR (C2869832, Extended per the JLCPCB page), SOT-23-5.
- Supply 3V3 with C10 100 nF; datasheet range is 1.6–6.5 V. Input range 0 … V+ (rail-to-rail).
- Its 3 µs propagation delay is < 2% of the shortest half-pulse (244 µs) and the same on every edge, so it cancels out in the pulse lengths.
- **The push-pull output is 0–3.3 V, so GPIO4 can never exceed its rails.** R13 (the old pull-up) is deleted.
- SOT-23-5 pinout: **1 OUT, 2 V-, 3 IN+, 4 IN-, 5 V+**, from KiCad's `Comparator:TLV7031DBV` symbol (shared with the MCP6561 and LMV7219, which have the same pinout).
- *Why the swap from LMC7211:* its pinout is only a top-view image in TI's datasheet, which I couldn't read, and KiCad has no LMC7211 symbol. The TLV7031 is electrically equivalent for this job and its pinout is library-verified.

**Simulation** (`python -I hardware/sim/frontend_sim.py exporrt2.wav`).
- **Model:** backward-Euler circuit integration of the exact network, a BAT54 exponential diode (≈0.24 V at 0.1 mA, 0.32 V at 1 mA) feeding current into the node, the source impedance, 50 Hz hum added at the source, comparator offset +3 mV (±8 mV in the worst-case rows), 1 mV rms noise, and a ROM-style decoder.
- **Pass criterion:** "OK" = both blocks of the recording decode (19-byte header + 57-byte data, both checksums good).
- The table lists **exactly** the script's cases, in order:

| Net | Rsrc | Vpp (open circuit) | Hum | Hyst | Decode | Node B min..max | Clamp peak | ADC pin | Centre shift |
|---|---|---|---|---|---|---|---|---|---|
| old | 100 Ω | 5.0 | 0 | 60 mV | OK | −0.31..3.60 V | 0.84 mA | −0.31..3.57 | 519 mV |
| old | 100 Ω | 6.0 | 0 | 60 mV | **FAIL** | −0.32..3.61 V | 1.13 mA | −0.32..3.60 | 548 mV |
| revA | 10 kΩ | 0.05 | 0 | 10 mV | OK | 1.62..1.67 | 0 | 1.62..1.67 | 0 |
| revA | 10 kΩ | 0.2 | 0 | 10 mV | OK | 1.53..1.74 | 0 | 1.53..1.74 | 0 |
| revA | 10 kΩ | 0.2 | 4× | 10 mV | OK | 1.53..1.75 | 0 | 1.53..1.75 | 0 |
| revA | 10 kΩ | 1.0 | 4× | 40 mV | OK | 1.06..2.15 | 0 | 1.07..2.15 | 0 |
| revA | 10 kΩ | 5.0 | 0.2× | 40 mV | OK | −0.21..3.49 | 0.04 mA | −0.20..3.48 | 88 mV |
| revA | 10 kΩ | 6.0 | 0 | 40 mV | OK | −0.22..3.51 | 0.06 mA | −0.21..3.51 | 101 mV |
| revA | 100 Ω | 0.2 | 4× | 10 mV | OK | 1.52..1.77 | 0 | 1.52..1.77 | 0 |
| revA | 100 Ω | 5.0 | 0.2× | 40 mV | OK | −0.23..3.53 | 0.08 mA | −0.22..3.52 | 115 mV |
| revA | 100 Ω | 6.0 | 0 | 10 mV | OK | −0.24..3.53 | 0.11 mA | −0.24..3.53 | 134 mV |
| revA | 100 Ω | 6.0 | 0 | 40 mV | OK | −0.24..3.53 | 0.11 mA | −0.24..3.53 | 134 mV |
| revA, offset +8 mV | 10 kΩ | 0.05 | 0 | 10 mV | OK | 1.62..1.67 | 0 | 1.62..1.67 | 0 |
| revA, offset −8 mV | 10 kΩ | 0.05 | 0 | 10 mV | **FAIL** | 1.62..1.67 | 0 | 1.62..1.67 | 0 |
| revA, offset +8 mV | 10 kΩ | 0.2 | 4× | 10 mV | OK | 1.53..1.75 | 0 | 1.53..1.75 | 0 |
| revA, offset −8 mV | 10 kΩ | 0.2 | 4× | 10 mV | OK | 1.53..1.75 | 0 | 1.53..1.75 | 0 |
| revA, offset −8 mV | 100 Ω | 6.0 | 0 | 40 mV | OK | −0.24..3.53 | 0.11 mA | −0.24..3.53 | 134 mV |

- **Worst-case offset (TLV7031, 8 mV max):** the whole 0.2–6 V p-p requirement still passes at ±8 mV. Only the 0.05 V p-p margin case fails at −8 mV, which is 4× below the requirement and ~6× below the real 48K level (~0.3 V p-p).

Notes on the table:
- **Hum at large signals:** 4× hum is only run at ≤ 1 V p-p. At 5 V, 4× hum would mean 20 V p-p, far beyond the 6 V safety spec, so the 5 V cases use 0.2× (5 + 1 = 6 V total).
- **Margin:** it decodes down to **0.05 V p-p**, 4× below the 0.2 V p-p requirement, which matters because the real 48K level is only ~0.3 V p-p.

**Safety check against the requirements (up to 6 V p-p):**
- **Comparator IN-:**
  - Node B stays within −0.24 … 3.53 V in all simulated cases, inside −0.3 … 3.6 V. IN- is behind R17 10k, so pin current is < 30 µA even if B overshoots.
  - Worst case not simulated: the recording's edges are limited to about 23 µs by the 44.1 kHz sampling. A real 0 Ω source with ns edges could pull B to about −0.38 V for ~1 µs (6 mA through D1). At IN- that's attenuated further, and the current stays < 10 µA. I judge this acceptable, but strictly it exceeds −0.3 V by 0.08 V at node B for about 1 µs.
- **GPIO5 (ADC):** −0.24 … 3.53 V in the simulation, behind R14 10k + C11 100 pF (τ = 1 µs), which also smooths the ~1 µs worst-case spike. Inside −0.3 … 3.6 V.
- **GPIO4:** driven by the 3V3-supplied push-pull output, so always 0 … 3.3 V.
- **Clamp current:** ≤ 0.11 mA simulated, ≤ 6 mA in the hand-calculated worst-case spike. The BAT54S is rated 200 mA.

### e) ADC tap ("built-in scope")
- Node B → R14 10k → GPIO5, with C11 100 pF to GND at the pin. GPIO5 sees the filtered signal centred on 1.65 V.
- **ADC range:** use 12 dB attenuation (0 … ~3.1 V) for large signals, or a lower attenuation for the real ~0.3 V p-p.
- **Accuracy caveat:** node B's source impedance is high (680k ∥ the C8 path). C11 acts as the charge reservoir for the ADC's sample capacitor; for level and waveform display at ≤ 20 kSa/s, expect a few-% error. That's fine for a level meter and a fallback software decoder, but it isn't a precision measurement.

### f) LEDs and test points
- **LEDs:** LED1 red power (3V3 → R15 1k) and LED2 red status (GPIO7 → R16 1k); same Basic part, so no extra fee (the green was out of stock).
- **J4: a 1×7 row of 2.54 mm plated through-holes, not populated (DNP)**: GND, 3V3, TX, RX, ADC, U0TXD, U0RXD. Chosen over JLCPCB THT assembly.
  - Hook probes and a Pico logic-analyser lead fit straight into the holes.
  - A header could still be added later, but nothing needs soldering to use them.
  - JLCPCB THT assembly would add a through-hole/hand-soldering setup fee plus per-joint charges (roughly a few USD; not verified) for a debug-only feature.
  - SMD-only pads would work too, but they're harder to clip onto.
- No BOM line: it's copper only.

### g) Board
- 2 layers, 1.6 mm. Size free; about **55 × 45 mm** is proposed, to fit the third button.
- USB-C, J2 EAR and J3 MIC on one edge; the module antenna overhangs the opposite edge (Espressif keep-out).
- Bottom-layer ground pour. The analogue front end is grouped by J3, away from the RF section and the LDO.
- 4 × M3 holes.

### h) Buttons
- **SW1 BOOT** (GPIO0, R4 10k pull-up): flashing only. **SW2 RESET** (EN).
- **SW3 PLAY** (new): GPIO8 → R18 10k pull-up to 3V3, C12 100 nF to GND, and the switch connects GPIO8 to GND **through R19 1k**.
  - Pressed: 3.3 V · 1k/11k = 0.30 V, well below the S3's V_IL of 0.25·VDD = 0.83 V.
  - τ_press ≈ 0.09 ms, τ_release = 1 ms.
  - *Why this works:* the RC swallows contact bounce, and R19 stops the switch dumping C12's charge instantly through its contacts.
  - Firmware adds a 20 ms software debounce, then tells a short press (play the tape) from a 5 s hold (erase Wi-Fi).

### i) Jacks J2/J3: Korean Hroparts PJ-320D-4A (C95562, SMD)
- **Switched from USAKRO PJ-320D (C521460)** at the KiCad stage: that part's pinout couldn't be verified.
- KiCad's `Connector_Audio:Jack_3.5mm_KoreanHropartsElec_PJ-320D-4A_Horizontal` footprint is drawn from **this exact part's** LCSC datasheet, and it names its pads **T, S, R1, R2**. The `AudioJack4` symbol uses the same pin names, so the tip/sleeve mapping comes from the library, not from guesswork.
- **Only tip and sleeve are used.** A mono plug's sleeve shorts both rings to sleeve, so the rings are left unconnected and a CTIA/OMTP-style ring swap can't matter.
- Basic/Extended class and stock: check at order time.

## 4. Nets

| Net | Connects |
|---|---|
| VBUS | J1 VBUS pins, U3 pin 5, U2 VIN, C1 |
| GND | J1 GND + shell, U1 GND, U2 GND, U3 pin 2, U4 pin 2 (V-), R1, R2, R10, R6 (DNP), C1–C6, C9, C10, C11, C12, SW1, SW2, SW3 (one side), LED1/LED2 cathodes, D1 pin 1, D2 pin 1, J2 sleeve, J3 sleeve, J4-1 |
| 3V3 | U2 VOUT, U1 3V3, C2–C5, R3, R4, R9, R15, R18, U4 pin 5 (V+), C10, D1 pin 2, D2 pin 2, J4-2 |
| CC1 / CC2 | J1 A5 → R1 / J1 B5 → R2 |
| USB_DP | J1 A6+B6, U3 I/O2, U1 GPIO20 |
| USB_DN | J1 A7+B7, U3 I/O1, U1 GPIO19 |
| EN | U1 EN, R3, C6, SW2 |
| BOOT | U1 GPIO0, R4, SW1 |
| PLAY | U1 GPIO8, R18, C12, R19 |
| BTN_PLAY_SW | R19, SW3 (other side of SW3 to GND) |
| TX_GPIO | U1 GPIO6, D2 pin 3, R5, J4-3 |
| EAR_OUT | R5, R6 (DNP), J2 tip |
| MIC_IN | J3 tip, R20 |
| MIC_R | R20, C7 |
| HP_A | C7, R7, C8 |
| HP_B | C8, R8, D1 pin 3, R17, R14 |
| CMP_IN | R17, U4 pin 4 (IN-) |
| VBIAS | R9, R10, C9, R7, R8, R11 |
| HYST | R11, RV1 (end) |
| CMP_REF | RV1 (wiper, tied to its other end), R12, U4 pin 3 (IN+) |
| RX | U4 pin 1 (OUT), R12, U1 GPIO4, J4-4 |
| ADC_TAP | R14, C11, U1 GPIO5, J4-5 |
| LED_STAT / LED_PWR | U1 GPIO7 → R16 → LED2 anode / 3V3 → R15 → LED1 anode |
| U0TXD / U0RXD | U1 GPIO43 / GPIO44, J4-6 / J4-7 |
| (NC) | J2/J3 ring pads, U1 GPIO3/45/46 and the spares |

Designator R13 is retired (it was the LM393 pull-up).

## 5. Extended parts and fees
- **Extended, verified:** U1 module, U3 USBLC6-2SC6, D1/D2 BAT54S, RV1 3314J. U4 TLV7031 is Extended per its JLCPCB page. J2/J3 PJ-320D-4A: class not yet checked.
- **Extended, likely but unverified:** J1 TYPE-C-31-M-12 (JLCPCB rate-limited my checks).
- **Unknown:** SW1–3 TS-1187A (its page shows no class).
- **Basic, verified:** U2 AMS1117. The 0402 UNI-ROYAL resistors, Samsung/FH 0402 capacitors and 0603 LEDs are Basic-type parts, but their class wasn't checked one by one.
- **Total: about 7 Extended part types (8 if the switch is Extended).** At the commonly quoted ~$3 setup fee each (third-party figure, not verified), that's about **$21–24 per order**.
- **Cheaper option:** BAT54S has no verified Basic equivalent, and a 1N4148W (Basic) clamp at ~0.6 V would break the −0.3 V limit, so it stays.

## 6. Still unverified
1. ~~The PJ-320D pinout~~ and ~~the comparator pinout~~: resolved by switching to parts whose KiCad symbols/footprints carry the pinout (§3d, §3i).
3. The 48K MIC series resistor (~10k) and the pin-28 node impedance. Only the pin-28 voltages are verified. The design tolerates 0.05–6 V p-p and a source impedance of 100 Ω–10 kΩ, so these mostly affect the expected level, not function.
4. Basic/Extended classes and live stock, where the BOM says so.
5. The real MIC level. The ADC tap measures it on the first board.

## 7. Open questions (rev A; settled by the rev B changes above)
1. A board of about 55 × 45 mm with three buttons along one side: OK?
2. Do you want the J4 test holes populated later by yourself (optional), or left as probe holes only?
