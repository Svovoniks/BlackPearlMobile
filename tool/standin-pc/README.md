# Stand-in PC

A room server and a stand-in BlackPearl PC in one Node.js process, so BlackPearl Mobile can be tried end to end on an
Android emulator without the desktop app. It follows `PHONE-REMOTE.md` like `--preview=loopback`
(`lib/debug/loopback.dart`) does, but runs outside the app: a normal debug build pairs with it through a real pairing
link, and it also offers the library: browsing, watching on the phone over `media-v1`, queues, watched marks and the
Unwatched row.

- **Room server**: `http://<bind>:<port>/remote` (the WebSocket) and `/health`.
- **Stand-in PC**: pairs phones with one-time codes, checks and signs every signal (HMAC-SHA256), answers the phone's
  offer with node-datachannel (libdatachannel, as the app uses), speaks `remote-v1` (hello/welcome, pair/paired,
  state every 5 s and after each command, commands that change a made-up player, errors) and `media-v1`.
- **A made-up library**: five films, two shows and an anime with seasons and episodes, two saved queues. Every
  playable entry plays the one real video given with `--video`. Pictures are generated JPEGs.
- **Its home-network socket** on port 47830 (or the next free one up to 47839), telling phones `10.0.2.2` in its
  `welcome`, so the app's fallback path can be tried with `server off`.

## Run it

Node 20 or later:

```sh
cd tool/standin-pc
npm install                                      # once
node index.js --video path/to/some.mkv --log standin.log
```

It prints the port and a pairing link, with `server=http://10.0.2.2:8790`: inside the emulator, `10.0.2.2` is this
computer's `127.0.0.1`, so **`adb reverse` is not needed**. The video file is only read, never changed.

## Pair the app on the emulator

With the app installed on the running emulator (`flutter build apk --debug --target-platform android-x64`, then
`adb install -r build/app/outputs/flutter-apk/app-debug.apk`), open the printed link (it also prints this line ready
to paste):

```sh
adb shell "am start -a android.intent.action.VIEW -p io.github.svovoniks.blackpearlmobile -d 'blackpearl://pair?v=1&pc=…&code=…&server=http%3A%2F%2F10.0.2.2%3A8790&name=Stand-in%20PC'"
```

The quotes matter: without them the device's shell cuts the link at the first `&`. `-p` picks the app (see
`--package`) when another installed app also takes `blackpearl://` links. A code is good for one pairing
and 10 minutes; after it is used or expires, the stand-in prints a new link (or type `pair`). Paired phones, the
PC's host key (so its PC id stays the same) and the library's resume points and watched marks are kept in
`.state/standin-pc.json`, so the app reconnects after either side restarts. Delete that file to start over.

## While it runs

Type on its stdin:

| Command | Does |
| --- | --- |
| `pair` | a new pairing code and link |
| `link` | prints the current link and the adb line again |
| `phones`, `forget <id>` | lists paired phones; removes one (the start of its id is enough), closing its session |
| `room` | joins or leaves a pretend room: `canControl` false, so all but volume, mute and fullscreen get `not-allowed` |
| `stop` | stops the PC's player (`media: false`) |
| `state` | prints the state the phones get |
| `server off`, `server on` | takes the room server down and back, to try the home-network socket |
| `quit` | stops everything |

## Options

| Option | Default | |
| --- | --- | --- |
| `--video <file>` | required | the real video every playable entry plays |
| `--conversion <folder>` | | a watch that asks for a conversion gets this one instead of the file: `stream.ts` (the whole video as one piece, converted as BlackPearl does, with `-copyts` and `-output_ts_offset 10`) and `subtitles.json`, the file's subtitle tracks in order as `{language, title, codec, default, burn, file}`; tracks with `burn` false are read as `subtitle/<stream id>/<index>` from `file` (SubRip or ASS, timed from the start of the video). The first track is shown unless the watch asks for another (`subtitle`, `-1` for none) |
| `--port <n>` | 8790 | room server port; 0 picks a free one |
| `--bind <address>` | 127.0.0.1 | where the room server and home-network socket listen; `0.0.0.0` for a real phone on the network (Windows Firewall will ask) |
| `--public-url <url>` | `http://10.0.2.2:<port>` | the room server as the phone reaches it, put in the pairing link; for a real phone, `http://<this PC's address>:<port>` |
| `--connect <url>` | | don't start a room server; connect the stand-in PC to this one |
| `--name <text>` | Stand-in PC | the PC's name |
| `--state <file>` | `.state/standin-pc.json` | host key, paired phones, resume points |
| `--log <file>` | | also append every log line to this file |
| `--features <list>` | `library,watch,mark-watched,queues,unwatched` | the welcome's features; `shuffle` and `tracks` also work (a `shuffle` field and command; made-up audio and subtitle tracks) |
| `--loading-ms <n>` | 0 | library requests wait this long (as BlackPearl's window does while it reads its library); past 15 s they get `loading` |
| `--lan-port <n>`, `--no-lan` | 47830 | the home-network socket's first port (it tries 9 more) |
| `--lan-address <list>` | 10.0.2.2 | the addresses its `welcome` gives phones |
| `--extra-candidate <ip>` | 10.0.2.2 | also offers each of the PC's ICE host ports at this address; `none` turns it off |
| `--log-reads` | off | one line per `media-v1` read and cancel, instead of a summary every 5 s |
| `--high-water <bytes>` | 1048576 | `media-v1` frames wait while this much is buffered on the channel, until it drops to a quarter |
| `--package <id>` | `io.github.svovoniks.blackpearlmobile` | the app the printed adb line opens the link in |

## The log

One line per event, on stdout and in `--log`: `<time> <side>: <event> key=value …`, where side is `server` (the room
server's connections), `pc` (sessions, signals refused, every `remote-v1` message received with its fields; commands
carry `pc-commands=` with all commands so far), `media` (`read-error`s and a summary of reads, bytes, cancels, busy
answers and the most buffered on the channel) and `lan` (the home-network socket). Keys, secrets and codes are never
logged except the pairing link itself; ids are cut to 8 characters.

## How the WebRTC link finds its way from the emulator

The PC's host candidates are this computer's network addresses, which the emulator reaches through its NAT. The PC
also offers each candidate's port at `10.0.2.2`, which the emulator maps to `127.0.0.1` here, so the link comes up
even without a usable network address. The emulator's own candidate (`10.0.2.15`) can't be reached from here, but it
doesn't have to be: the PC learns the emulator's mapped address from its connectivity checks. No STUN or TURN servers
are handed out (`iceServers: []`).

## Self-test

`npm test` checks the signatures against the spec's test vectors, then starts `index.js` as a child process with a
temporary state file and drives a scripted phone (node-datachannel too) through the room server: pairing, the
`pairing-expired` and `unknown-phone` hints, commands, browsing (Home, a category, a show's seasons and episodes,
queues, Unwatched), watched marks, `watch`, `media-v1` reads of several MiB compared byte for byte with the file
(windowed, a burst of 48, the end of the file, past it, a picture, bad reads, more than 64 waiting → `busy`,
`cancel`), `progress` and `play`; then restarts the stand-in and links again as the paired phone, through the room
server and through the home-network socket. The video is `$STANDIN_VIDEO`, else a made-up 6 MiB file.

## Not covered

- Conversions (`kind: "hls"`, `stream/<id>/<piece>` reads get `gone`), `listen`/`sound`/`clock` (Sound on the phone):
  the stand-in offers neither, so the app never asks.
- The room server's message rate limits; on the home-network socket, the per-address limit of 4 unproven connections
  and eviction, the 6-hour cap and the 256 KiB / 8 KiB size limits (only 8 connections, the 10 s greeting and the
  30 s proof deadline are enforced).
- The desktop's diagnostics log format (`logs/diagnostics.jsonl`); this tool writes its own lines instead.
