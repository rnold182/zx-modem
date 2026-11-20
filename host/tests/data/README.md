# Test data

## zx48k-save-test.wav

A real recording of a 48K Spectrum, `SAVE "test"` of a short BASIC
program, taken from the MIC socket into the PC's line-in (2026-11-02).

- 44.1 kHz, 16-bit stereo. **The signal is on the left channel (0)**; the right
  channel is silence.
- About 17,000 counts peak-to-peak, no clipping, noise floor ~40 counts RMS.
- Two blocks, both with valid checksums:
  - header (flag `0x00`): type 0 (program), name `test`, length 55,
    autostart 32768 (none), program length 55
  - data (flag `0xFF`): 55 bytes of BASIC (4 lines, `40 GO TO 10` loop)
- Measured with a reference decoder (mean pulse lengths, ROM values in brackets):
  - pilot 2168.6 T (2168)
  - bit 0 half 854.4 T (855)
  - bit 1 half 1714.6 T (1710)
  - spread about +/-37 T, i.e. half a sample at 44.1 kHz
- Pilots: header 8049 pulses seen (8063 sent), data 3212 (3223); the few
  missing are the decoder locking on late.

Use: the first real-signal test for `wav2tap` (M1a). `wav2tap` must produce
both blocks with valid checksums.
