# sdk: what Spectrum apps build against

| File | What |
|---|---|
| `zxmodem_api.inc` | the API contract: fixed addresses of the menu's routines and shared variables, memory limits for apps |
| `ui.inc` | colours, glyph numbers |
| `zxsys.inc` | ROM entry points, system variables, key codes |

Apps include these and nothing else from the modem: no paths into `zx/`,
`esp32/` or the menu's source. That is what lets an app (like the browser in
`apps/zx-vvv/`) live and be built on its own.

Assemble with `sjasmplus --inc=sdk <app>.asm`. The guide is
[`docs/app-api.md`](../docs/app-api.md); the wire protocol is
[`docs/link-protocol.md`](../docs/link-protocol.md).
