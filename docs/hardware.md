# Hardware

The modem is an **ESP32-S3 SuperMini** dev board on a small carrier PCB
(53 x 26 mm) with the two 3.5 mm jacks, the MIC input stage, the EAR output
and a PLAY button. Full design notes, the simulation of the input stage and
the parts list: [`hardware/DESIGN.md`](../hardware/DESIGN.md). The KiCad
project and its generator scripts are in [`hardware/kicad/`](../hardware/kicad/).

## Connections

```
 ESP32 GPIO6 (TX) --+--[220R]-- EAR jack --> Spectrum EAR socket
                    |
      BAT54S clamp to 3V3 / GND (protects the GPIO)

 Spectrum MIC socket --> MIC jack --[1k]--[10n]--[1n]--+-- TLV7031 comparator --> GPIO4 (RX)
      (2-pole 234 Hz high-pass, BAT54S clamp,           |
       1.65 V bias, 10.5 mV hysteresis)                 +-- [10k] --> GPIO5 (ADC tap)

 PLAY button --> GPIO7 (10k pull-up, 1k + 100n debounce)
 Status LED: the SuperMini's RGB LED on GPIO48
 Power: the SuperMini's own USB-C. Never from the Spectrum.
 Ground: both jack sleeves to the board's GND.
```

- **EAR (modem -> Spectrum):** a 0/3.3 V square wave through 220 ohm is
  plenty; the Spectrum's EAR input only looks for edges.
- **MIC (Spectrum -> modem):** the 48K's MIC output is a few hundred mV and
  can carry 50 Hz hum, hence the high-pass filter before the comparator.
  Measured on a real 48K: clean edges, ROM timings within 0.3 %.

## Pins

| SuperMini pin | Use |
|---|---|
| GPIO4 | RX, from the comparator |
| GPIO5 | ADC tap of the filtered MIC signal (diagnostics) |
| GPIO6 | TX, to EAR |
| GPIO7 | PLAY button, active low |
| GPIO48 | RGB status LED (on the SuperMini) |

A classic ESP32 dev board works too (`idf.py set-target esp32`): TX GPIO25,
RX GPIO26, the BOOT button (GPIO0) as PLAY, LED on GPIO2. Its MIC input still
needs a comparator stage like the one above.

## Board revisions

| Rev | Status | Jacks |
|---|---|---|
| **C** (current files) | designed and checked, **not built yet** | correct: signal on pin 5 (tip), ground on pins 1 and 2 |
| B | built (first batch) | **signal and ground swapped**: see below |

The order files for rev C are in `hardware/fab/`: Gerbers, BOM and
placement for JLCPCB (Economic PCBA; you solder only the SuperMini).
`hardware/kicad/make_fab.py` regenerates them.

### Rev B jack issue

The PJ-307 jacks JLCPCB fits (HOOYA, LCSC C2939173) have **tip = pin 5,
ring = pin 2**, the other way round from the jacks the pinout was first
measured on. So rev B boards have the signal on the ring contact and ground
on the tip. Workarounds, with no board changes:

- solder a mono cable to the underside joints: core to pin 2, shield to
  pin 1, and plug nothing into the jacks; or
- use a stereo plug-to-socket adapter with tip and ring swapped, or a cable
  wired board-side ring to Spectrum-side tip.

## Debugging without instruments

- **A PC sound card as a scope:** record the Spectrum's MIC output into
  line-in; the repository's tape decoder reads such recordings (see
  `host/tests/data/`).
- **The modem as its own analyser:** it logs every block it decodes, with
  checksums, over USB serial (`idf.py monitor`).
- **The tape test** (hold PLAY 2-5 s) checks both directions in one go: the
  Spectrum loads a program over EAR and saves known ROM bytes back over MIC.
