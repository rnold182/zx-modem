# Wi-Fi Setup (app 1)

The ZX MODEM's Wi-Fi screen: scan, pick a network, type its password. Saved
networks (up to 5) are marked and join without a password; F forgets one.

- **Kind 1** app: loads at 0xA000, uses the menu's routines through
  `sdk/zxmodem_api.inc`, returns to the menu.
- **Modem side:** the system service's `L`, `J` and `F` commands
  (`docs/link-protocol.md` §6.1); no code of its own on the ESP32.
- **Build:** `sjasmplus --inc=sdk apps/wifisetup/wifisetup.asm` ->
  `wifisetup.bin`, which the firmware embeds (`esp32/main/apps.c`).
