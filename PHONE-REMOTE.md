# Phone remote protocol, version 1

BlackPearl Mobile (a separate Flutter app, repository `Svovoniks/BlackPearlMobile`) controls the BlackPearl
desktop app from a phone, on the same network or across the internet. This file is the contract between the
desktop app, the room server and the phone app. A copy lives in both repositories; change both together.

## Shape

- The phone and the PC talk over one WebRTC data channel, labelled `remote-v1`, reliable and ordered. The phone
  creates it and makes the offer; the PC answers.
- The room server (the `/remote` WebSocket on the server in `deploy/`) only introduces them: it forwards signaling
  messages and hands both sides STUN/TURN servers, the same ones rooms use. Commands and state never pass through it.
- Each signaling message is signed with a key only the phone and the PC know, so the server cannot answer in the
  PC's place or insert itself: the SDP carries the DTLS fingerprints, and a forged SDP fails the signature.
- ICE finds the local network path by itself when both are at home. When no direct path exists, TURN carries the
  link.

## Identities and keys

| Name | Form | Who makes it | Who knows it |
| --- | --- | --- | --- |
| host key | 64 hex characters, random | PC, once | PC and server (the server uses it only to derive the PC id) |
| PC id | first 32 hex characters of upper-case SHA-256 hex of the host key's UTF-8 bytes | derived | PC, server, paired phones |
| pairing code | 32 hex characters (16 random bytes) | PC, for each pairing; one use, 10 minutes | PC, and the phone that scans it |
| phone id | 32 hex characters, random | PC, at pairing | PC, that phone |
| phone secret | 64 hex characters (32 random bytes) | PC, at pairing | PC, that phone |

Hex in ids and keys is compared case-insensitively. The server computes the PC id as
`Convert.ToHexString(SHA256(UTF8(hostKey)))[..32]`, so it is upper case on the wire.

Removing a phone on the PC deletes its secret. Its signatures stop verifying at once, wherever it is.

## Pairing link

The PC shows this as a QR code (and as text to copy):

```
blackpearl://pair?v=1&pc=<PC id>&code=<pairing code>&server=<room server URL, percent-encoded>&name=<PC name, percent-encoded>
```

`server` is the base URL the PC uses for rooms, such as `https://rooms.example.com`. The phone opens
`wss://<host>/remote` (or `ws://` for an `http://` server). The Android app registers for `blackpearl://pair` so a
camera app can open it.

## Room server: `/remote`

A WebSocket carrying the room service's message envelope: JSON objects with the camelCase fields
`type`, `target`, `sender`, `text`, `data` (a string) and `number`. Fields that don't apply are omitted or null.
Messages are at most 64 KiB. `{"type":"ping","number":n}` is answered with `{"type":"pong","number":n,"data":"<server ms>"}`.

**PC** sends first: `{"type":"remote-pc","data":"<host key>","number":1}`.
The server answers `{"type":"remote-welcome","target":"<PC id>","data":"<json>"}`, where the json is
`{"iceServers":["stun:…","turn://user:pass@host:port?transport=udp", …]}`. One connection per PC id: a new one
replaces the earlier. The connection lasts at most 6 hours; the PC reconnects and gets fresh relay credentials.

**Phone** sends first: `{"type":"remote-phone","target":"<PC id>","number":1}`.
The server answers `{"type":"remote-welcome","target":"<this connection's id>","data":"<json with iceServers>"}`,
then `{"type":"remote-online"}` if the PC is connected, or `{"type":"remote-offline"}` if not. While the phone
stays connected it receives `remote-online` and `remote-offline` as the PC comes and goes.

**Signals.** Phone → PC: `{"type":"signal","data":"<signed signal json>"}` (no target needed; the server sends it
to the PC this phone asked for, with `sender` set to the phone's connection id). PC → phone:
`{"type":"signal","target":"<phone connection id>","data":"<signed signal json>"}`; the server delivers it with
`sender` set to the PC id. When a phone's connection closes, the PC gets `{"type":"peer-left","sender":"<connection id>"}`.

An error ends the connection with `{"type":"error","text":"<reason>"}`. A `number` other than 1 is refused with a
reason telling which side to update. `/health` lists `"remote":1` when the server has this endpoint.

Limits: 8 phone connections per PC at a time, and the same message rate limits as rooms.

## Signed signals

```json
{"phone":"<phone id, or \"pair\" while pairing>","session":"<32 hex>","kind":"sdp|ice|rejected","payload":"<string>","auth":"<base64url, no padding>"}
```

- `session` is new for every connection attempt; the phone makes it. The PC keeps one live session per phone, and
  a new session replaces the old one.
- `payload` for `sdp` is the JSON text `{"type":"offer|answer","sdp":"<SDP>"}`; for `ice` it is
  `{"candidate":"<candidate line, without the a= prefix>","mid":"<media id>"}`. ICE is trickled both ways.
- `auth` is HMAC-SHA256 with key = the phone secret's bytes (or, while pairing, the pairing code's 16 bytes) over the
  UTF-8 bytes of

  ```
  bp-remote-v1\n<direction>\n<phone>\n<session>\n<kind>\n<payload>
  ```

  where `<direction>` is `phone` for messages the phone sends and `pc` for the PC's, `\n` is a single line feed, and
  `<payload>` is the payload string exactly as sent.
- Both sides drop a signal whose `auth` doesn't verify, without answering, except for one case: when the PC doesn't
  know the phone id, or its pairing code has expired or been used, it answers once per session with an
  **unsigned** `{"phone":…,"session":…,"kind":"rejected","payload":"unknown-phone|pairing-expired","auth":""}`.
  The phone shows "This phone was removed from the PC. Pair it again." or "That code has expired". It is a hint only:
  it can't grant anything.

Test vectors:

| key (hex) | text signed | auth |
| --- | --- | --- |
| `000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f` | `bp-remote-v1⏎phone⏎a1b2c3d4e5f60718a1b2c3d4e5f60718⏎0123456789abcdef0123456789abcdef⏎sdp⏎{"type":"offer","sdp":"v=0"}` | `AHCUPPyOcWPNmRtEBJ6D5PQUJwF9CV5-GHlhUpfTkX8` |
| `ffeeddccbbaa99887766554433221100` | `bp-remote-v1⏎pc⏎pair⏎0123456789abcdef0123456789abcdef⏎ice⏎{"candidate":"candidate:1 1 UDP 2122317823 192.168.1.20 50000 typ host","mid":"0"}` | `bIGb4K6s3ztFQAOUL2Q3Oof397tsk3TiGq_W2ZB3I_I` |

(⏎ is a line feed.)

## The data channel, `remote-v1`

UTF-8 JSON text messages, at most 64 KiB, each with a `type`.

### Opening

1. Phone → PC: `{"type":"hello","protocol":1,"app":"<app version>","device":"<phone model or name>"}`
2. PC → phone: `{"type":"welcome","protocol":1,"app":"<desktop version>","pc":"<PC name>","pcId":"<PC id>","canStart":true}`.
   If the PC can't speak the phone's protocol it sends `{"type":"error","code":"protocol","message":"…"}` saying which
   app to update, and closes.
3. While pairing (the session was signed with a pairing code), the phone then sends
   `{"type":"pair","name":"<name to show on the PC>"}` and the PC answers
   `{"type":"paired","phoneId":"<phone id>","secret":"<phone secret>","pc":"<PC name>","pcId":"<PC id>"}`. The code is
   used up. The phone saves what it needs and from then on connects with its own id and secret. A paired session
   that sends `pair` gets an error.
4. The PC sends a `state` at once, then whenever it changes.

### PC → phone

`state`:

```json
{"type":"state",
 "media":true,                 // false when nothing is loaded in the player; the other playback fields are then absent
 "title":"Night Signal",
 "detail":"Season 2 · Episode 3 · Low Tide",
 "playing":true,
 "positionMs":1122000, "durationMs":2830000,
 "volume":64, "muted":false,
 "loop":"off|all|one",
 "fullscreen":false,
 "hasPrevious":true, "hasNext":true,
 "canControl":true,            // false in a room where only whoever plays the video may control it
 "room":null}                  // or {"name":"Movie club","people":3} while the PC is in a room
```

While playing, the phone advances the position itself from when the message arrived; the PC also sends a fresh
`state` every 5 seconds and after every seek.

`error`: `{"type":"error","code":"<short code>","message":"<sentence to show>"}` for a command that couldn't be
done, such as `not-allowed` in a room where only the person playing the video can control it, or `nothing-playing`.

### Phone → PC

`command`: `{"type":"command","action":"<action>","value":<number or bool, when the action takes one>}`

| action | value | does what the PC's … does |
| --- | --- | --- |
| `toggle` | | Space |
| `play`, `pause` | | media Play / Pause buttons |
| `seek-by` | milliseconds, negative to go back | Left / Right (±10 s) |
| `seek-to` | milliseconds from the start | dragging the timeline |
| `previous`, `next` | | P / N |
| `stop` | | S |
| `volume` | 0–100 | the volume slider |
| `mute` | | M |
| `loop` | | L (off → all → one) |
| `fullscreen` | | F |

Commands go through the same code as the PC's keys and buttons, so a room's shared-controls rule applies to them
the same way.

Unknown message types and actions are ignored, so either side can add new ones within version 1. Changing the
meaning of an existing message needs version 2.
