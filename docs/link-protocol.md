# ZX Modem Link Protocol 1

The standard for talking to the ZX MODEM: an ESP32 connected to an
unmodified ZX Spectrum through its EAR and MIC sockets. This file is
authoritative; `CLAUDE.md` §7 is only a summary. The Spectrum-side
programming interface (the API table apps call, and the BASIC entry points)
is in [`app-api.md`](app-api.md).

- **Protocol version:** 1. It is sent in every response header (§5.1) and
  in the `info` reply (§6.1).
- **Status:** in use since firmware 0.2. Sections marked *(planned)* are not
  implemented yet.
- **Terms:** the *modem* is the ESP32 firmware. A *client* is a Spectrum
  program that uses it: the ZX MODEM menu, an app, a BASIC program. A
  *service* is a group of commands with a number (§4).

## 1. Overview

The modem and the Spectrum use the standard ROM tape signal in both
directions, so the Spectrum needs no audio code of its own: it saves
requests with the ROM's `SA-BYTES` and loads responses with `LD-BYTES`.

The link is **half-duplex and request driven**. The client always speaks
first; the modem answers each request with exactly one response, then
listens again. The link layer knows nothing about what the bytes mean: each
request names a service and a command, and services are free to define
their own data.

## 2. Physical layer (tape signal)

### 2.1 Timing

Standard ROM timing, in T-states at 3.5 MHz (1 T = 0.2857 us):

| Element | T-states |
|---|---|
| pilot pulse | 2168 |
| sync 1 / sync 2 | 667 / 735 |
| bit 0 / bit 1 (each of two pulses) | 855 / 1710 |

Pilot length:

| Who sends | Pilot pulses | Why |
|---|---|---|
| client (`SA-BYTES`, flag >= 0x80) | 3223 (~2 s) | fixed by the ROM |
| modem responses | 3223 (~2 s) | see below |
| modem bootstrap tape (PLAY) | ROM standard (8063 / 3223) | a plain `LOAD ""` |

Responses can't use a shorter pilot: after the first edge, `LD-BYTES` waits
almost 1 s on purpose (`LD-WAIT`, ROM 0571), then needs 256 pairs of pilot
pulses (~0.32 s). A pilot under ~2200 pulses is over before the ROM starts
listening. Only a client's own loader can shorten it *(planned, M6)*.

Polarity doesn't matter; both sides time the gaps between edges.

### 2.2 Block format

`flag, payload..., checksum`: the checksum is the XOR of all preceding
bytes; bits go MSB first, two pulses per bit. The receiver must know the
length in advance (`LD-BYTES` does), which is why every response starts
with a fixed-size header block (§5).

### 2.3 Gaps and turnaround

- The modem treats **20 ms without an edge** as the end of a block.
- After a request the client calls `LD-BYTES` at once; it waits as long as
  needed for the response's pilot (SPACE aborts).
- The modem leaves **200 ms** of silence after each block it sends, so the
  client can look at a header before the next pilot starts.
- The modem ignores its receiver while it transmits, plus 300 ms: on a 48K,
  EAR and MIC share a ULA pin, so its own signal echoes back on MIC.

## 3. Packet flags

| Flag | Direction | Meaning |
|---|---|---|
| `0x00` / `0xFF` | modem -> Spectrum | ROM header/data (bootstrap tape only) |
| `0x80` | client -> modem | request |
| `0x90` | modem -> client | response header (10 bytes) |
| `0x91` | modem -> client | response data chunk |

Other flags from the Spectrum (a normal `SAVE`) are not requests; the modem
only logs them. Flags `0x81`-`0x8F` and `0x92`-`0x9F` are reserved.

## 4. Registry

New numbers are added here, in the same change that implements them.

### 4.1 Services

| Service | Name | Defined in |
|---|---|---|
| `0x00` | system: status, Wi-Fi, apps | §6.1 |
| `0x01` | http: web requests for clients with their own rules (zx-vvv) | §6.4 |
| `0x02` | files: tape library, SAVE storage | *(reserved)* |
| `0x03` | basic: plain web fetch | §6.2 |
| `0x04` | at: Zimodem-style AT commands | §6.3 *(planned)* |
| `0x05`-`0x3F` | more services, for apps | assigned here |
| `0x40`-`0x7F` | experimental / private | never assigned; may clash |
| `0x80`-`0xFF` | reserved | |

An app that needs its own modem-side code gets a service number from the
`0x05`-`0x3F` range, and documents its commands in its own folder.

### 4.2 Response types (header byte 0)

| Type | Name | Used by |
|---|---|---|
| 0 | body | basic `F`, http `G` |
| 1 | error: data is a short ASCII message | all |
| 2 | reserved (once planned for stylesheets; never used) | |
| 3 | url-info: the final URL and content type | http `G` |
| 4 | netlist | system `L`, `F` |
| 5 | wifi | system `J` |
| 6 | app code: header bytes 4-5 = load address | system `O` |
| 7 | info | system `V` |
| 8-63 | reserved for this document | |
| 64-127 | defined by the service that sends them | |
| 128-255 | reserved | |

### 4.3 Apps

The modem lists its apps in the `info` reply (§6.1) and sends one with
system `O <id>`. Ids are permanent.

| Id | App | Folder |
|---|---|---|
| 1 | Wi-Fi Setup | `apps/wifisetup/` |
| 2 | zx-vvv (the 8TML browser) | `apps/zx-vvv/` |
| 3 | Tape Loader (LAN) | *(planned)* |
| 4-127 | more apps | assigned here |

## 5. Framing

### 5.1 Requests (client -> modem)

One block, flag `0x80`, payload at most 320 bytes (300 before firmware
0.7):

```
[service:1] [command:1] [arguments...]
```

The modem finds the end of the block from the silence after it, so there is
no length field. Commands are single ASCII letters by convention.

### 5.2 Responses (modem -> client)

One or more `header (0x90)` + `data (0x91)` pairs. The data block is left out
when its length is 0. Header (10 bytes):

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | response type (§4.2) |
| 1 | 1 | flags: bit 0 final chunk, bit 1 data cut short by the modem |
| 2 | 2 | chunk length (LE): the data block that follows, 0 = none |
| 4 | 2 | total length (LE, clamped to 65535); for type 6 the load address |
| 6 | 1 | chunk index, from 0 |
| 7 | 1 | protocol version (1) |
| 8 | 2 | HTTP status (LE) for web responses, else 0 |

### 5.3 Chunking

The modem chooses the chunk size; the client appends chunks until it sees
the final flag, so it must accept any chunk that fits its buffer. Every
block costs a ~2 s pilot (§2.1), so the modem sends every reply as one
chunk (firmware 0.7; 1024-byte chunks before). Smaller chunks would only
pay off with a re-send command for a chunk after a tape error *(not
planned until tape errors show up in use)*.

## 6. Services

### 6.1 System (0x00)

| Cmd | Args | Reply |
|---|---|---|
| `V` | none | `info` (type 7) |
| `L` | none | scan Wi-Fi: `netlist` (type 4), or `error` |
| `J` | see below | join Wi-Fi: `wifi` (type 5), or `error` with the reason |
| `F` | `[index]` | forget a saved network: `netlist` (the last scan, not rescanned), or `error` |
| `O` | `[app id]` | app code (type 6), or `error` (`No such app`, `Coming soon`) |

**`info` data (type 7):**

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | firmware version, major |
| 1 | 1 | firmware version, minor |
| 2 | 1 | protocol version (1) |
| 3 | 1 | Wi-Fi state: 0 not set up, 1 connecting, 2 connected |
| 4 | 4 | IPv4 address, first octet first (0.0.0.0 if none) |
| 8 | 1 | RSSI in dBm, signed (0 if not connected) |
| 9 | 1 | clock valid: 1 once NTP has set the time |
| 10 | 2 | year (LE) |
| 12 | 1 | month 1-12 |
| 13 | 1 | day 1-31 |
| 14 | 1 | hour 0-23 (local time) |
| 15 | 1 | minute |
| 16 | 1 | second |
| 17 | 1 | day of week, 0 = Sunday |
| 18 | 1 | SSID length n (0-32) |
| 19 | n | SSID, printable ASCII (other bytes become `?`) |
| 19+n | 1 | number of apps *(firmware 0.6+)* |
| ... | | per app: `[id][kind][flags][name length][name]`; kind 1 = runs at 0xA000 and returns, 2 = replaces the client program; flags bit 0 = available (else listed as coming soon); name up to 24 characters |

**`netlist` data (type 4):** up to 19 records, strongest first, one per
network name (hidden networks left out):

| Size | Field |
|---|---|
| 1 | RSSI in dBm, signed |
| 1 | auth mode (ESP-IDF `wifi_auth_mode_t`; 0 = open) |
| 1 | flags: bit 0 saved in the modem, bit 1 connected now |
| 1 | name length n |
| n | name, printable ASCII (other bytes become `?`) |

The modem keeps the real names and the order, for `J` and `F`.

**`J` arguments:**

- `[index] [password...]`: join entry `index` of the last `L` list.
- `[0xFF] [name...] [0x00] [password...]`: join a network by name (hidden).

The password runs to the end of the request, no terminator; empty for an
open network, and for a saved network (the modem uses the saved one). A join
takes up to ~15 s (the client waits in `LD-BYTES`). On success the network is
saved (up to 5, most recently used first) and the reply is `wifi` (type 5)
with data `[ip0][ip1][ip2][ip3]`. On failure the reply is `error` with one
of `Wrong password`, `Network not found`, `No IP address`,
`Could not connect`, `Scan again`, and the modem goes back to its saved
networks.

**Saved networks:** whenever it isn't connected, the modem scans and joins
the strongest saved network in range, and looks again every 10 s. A network
set in menuconfig is used only while nothing has ever been saved. Holding
PLAY for 5 s forgets all saved networks.

### 6.2 BASIC (0x03)

A plain web fetch for any program, with no 8TML rules.

| Cmd | Args | Reply |
|---|---|---|
| `F` | `[max:2 LE] [url...]` | `body` (type 0) or `error` |

- The URL may leave out the scheme (`host/path` means `http://host/path`);
  `https://` works (the modem does TLS).
- Redirects (301/302/303/307/308) are followed, up to 5. Timeout 30 s.
- The body comes back whatever the HTTP status, which is in the header. It
  is converted from UTF-8 to ASCII (`components/translit`) and cut to `max`
  bytes; header flag bit 1 says it was cut.
- `error` only when there is no answer at all: `No Wi-Fi`,
  `Could not connect`, `Timed out`, `Too many redirects`, `Bad address`,
  `No address`.

### 6.3 AT (0x04) *(planned)*

Familiar Hayes-style commands for BASIC programs, after
[Zimodem](https://github.com/bozimmerman/Zimodem) (Bo Zimmerman, Apache-2.0):
the request is `[0x04]['A'][command text]`, e.g. `ATI` or `AT&G"host/file"`,
and the reply is the command's text output (type 0) or `error`. Only the
command names and meanings follow Zimodem; the transport stays this
protocol's blocks, since a tape link can't carry Zimodem's continuous byte
stream.

### 6.4 HTTP (0x01)

A web client for programs that apply their own rules: the 8TML browser
zx-vvv uses it. The modem only does the transport: it doesn't resolve
relative addresses, add file names or look inside the body. Which types to
take, what to ask for and what an address means stay the client's decisions.

| Cmd | Args | Reply |
|---|---|---|
| `G` | `[flags] [max:2 LE] [url] 0 [accept] 0 [refuse]` | `url-info` (type 3), then `body` (type 0); or `error` |
| `C` | `[chunk]` | *(planned)* the last body again, from chunk n |
| `P` | | *(planned)* POST a form |

**`G` arguments:**

- `flags`: bit 0 = convert the body from UTF-8 to ASCII
  (`components/translit`). Bit 1 = **one reply** (firmware 0.7+): a single
  `body` (type 0) whose data is `[final url] 0 [content type] 0 [body]`,
  instead of `url-info` then `body`. It saves two tape blocks (about 4 s
  of pilot); `max` then covers all of it. Other bits 0.
- `max`: the most body bytes the client takes; a longer body is cut (header
  flag bit 1).
- `url`: an absolute `http://` or `https://` address, sent as it is. The
  client resolves relative links and leaves out any `#fragment`.
- `accept`: the `Accept` header to send; empty = no `Accept` header.
- `refuse`: content types to refuse, separated by spaces. One ending in `/`
  refuses every type that starts with it (`image/`); any other must match
  the whole type. Case and parameters (`; charset=...`) are ignored. Empty =
  take anything.

**What the modem does:** it follows redirects (301, 302, 303, 307, 308; up to
5; a relative `Location` is resolved against the address that sent it),
then checks the final response's content type against `refuse` **before
reading the body**, so a refused body never goes on tape. The body comes
back whatever the HTTP status. Timeout 30 s.

**`url-info` data (type 3):** `[final url] 0 [content type]`: the address
after redirects, then the type in lower case without parameters (empty if
the server sent none). Its header carries the HTTP status, like the
`body` after it.

**`error` data:** `[code] [message]`, the code a byte from this table, then a
short ASCII message:

| Code | Message | When |
|---|---|---|
| 1 | `No Wi-Fi` | not connected |
| 2 | `Bad address` | not an absolute http/https address, or too long |
| 3 | `Could not connect` | DNS, TCP or TLS failed |
| 4 | `Timed out` | no answer in 30 s |
| 5 | `Too many redirects` | more than 5 in a row |
| 6 | the content type | refused by `refuse` |
| 7 | `Bad request` | arguments missing |

For code 6 the header's `http_status` is the status the server answered
with (firmware 0.8 on; 0 before): a client can tell "this server sent an
HTML error page" (e.g. 404) from "this page is in a type I don't read"
(200). For the other codes it is 0.

## 7. Compatibility rules

- **Within version 1** the modem may add services, commands, response types
  and apps, and may **append** fields to the end of a reply's data. Clients
  ignore data past the fields they know, and must check lengths before
  reading (e.g. the app list after the SSID only exists from firmware 0.6).
- A client that gets `error` "Unknown request" knows the command is missing.
- Changing the meaning or layout of an existing field needs version 2,
  carried in header byte 7 and the `info` reply.

## 8. Error handling

- A request the modem can't decode (bad checksum) gets no reply: the user
  presses SPACE and retries.
- `error` responses (type 1) carry a short ASCII message, meant for a
  status line (up to 31 characters). A service may start the data with a
  code byte 1-31 of its own (http does, §6.4); the message follows it.
- Unknown services or commands get `error` "Unknown request".
