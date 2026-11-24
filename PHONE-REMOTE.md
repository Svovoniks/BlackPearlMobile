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

`server` is the base URL the PC uses for rooms, such as `https://rooms.example.com`. The phone opens `<server>/remote`
with `wss` for `https` (or `ws` for an `http://` server), keeping any path the server URL has. The Android app registers for `blackpearl://pair` so a
camera app can open it.

## Room server: `/remote`

A WebSocket carrying the room service's message envelope: JSON objects with the camelCase fields
`type`, `target`, `sender`, `text`, `data` (a string) and `number`. Fields that don't apply are omitted or null.
Messages are at most 64 KiB. `{"type":"ping","number":n}` is answered with `{"type":"pong","number":n,"data":"<server ms>"}`.

**PC** sends first: `{"type":"remote-pc","data":"<host key>","number":1}`.
The server answers `{"type":"remote-welcome","target":"<PC id>","data":"<json>"}`, where the json is
`{"iceServers":["stun:…","turn://user:pass@host:port?transport=udp", …],"forceRelay":false}`; user and password are
percent-encoded, and `forceRelay` true means both sides use only relay candidates. One connection per PC id: a new one
replaces the earlier. The connection lasts at most 6 hours; the PC reconnects and gets fresh relay credentials.

**Phone** sends first: `{"type":"remote-phone","target":"<PC id>","number":1}`.
The server answers `{"type":"remote-welcome","target":"<this connection's id>","data":"<json with iceServers>"}`,
then `{"type":"remote-online"}` if the PC is connected, or `{"type":"remote-offline"}` if not. While the phone
stays connected it receives `remote-online` and `remote-offline` as the PC comes and goes.

**Signals.** Phone → PC: `{"type":"signal","data":"<signed signal json>"}` (no target needed; the server sends it
to the PC this phone asked for, with `sender` set to the phone's connection id). PC → phone:
`{"type":"signal","target":"<phone connection id>","data":"<signed signal json>"}`; the server delivers it with
`sender` set to the PC id. When a phone's connection closes, the PC gets `{"type":"peer-left","sender":"<connection id>"}`.

An error ends the connection with `{"type":"error","text":"<reason>"}`. A PC connection replaced by a newer one gets
`{"type":"closed","text":"<reason>"}` before it ends. A `number` other than 1 is refused with a
reason telling which side to update. `/health` lists `"remote":1` when the server has this endpoint.

Limits: 8 phone connections per PC at a time, and the same message rate limits as rooms.

## Signed signals

```json
{"phone":"<phone id, or \"pair\" while pairing>","session":"<32 hex>","kind":"sdp|ice|rejected","payload":"<string>","auth":"<base64url, no padding>"}
```

- `session` is new for every connection attempt; the phone makes it. The PC keeps one live session per phone, and
  a new session replaces the old one. A session that began with a pairing code keeps signing as `pair`, with the
  pairing code, for the rest of its life, even after it has paired.
- `payload` for `sdp` is the JSON text `{"type":"offer|answer","sdp":"<SDP>"}`; for `ice` it is
  `{"candidate":"<candidate line, without the a= prefix>","mid":"<media id>"}`. ICE is trickled both ways. There is
  only one media section, the data channel's, so a receiver that needs a line index uses the one in the answer (0).
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
  A `pair` offer signed with a code that isn't the PC's live one (a newer code replaced it, or it was never this
  PC's) gets `pairing-expired` too, from PCs after 0.3.144; earlier ones answer it with nothing. The phone shows
  "This phone was removed from the PC. Pair it again." or "That code has expired". It is a hint only: it can't grant
  anything. A pairing offer that gets no answer at all within 20 seconds is not tried again either (the phone asks for
  a new code), as an older PC's silence about a replaced code looks the same.

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
2. PC → phone: `{"type":"welcome","protocol":1,"app":"<desktop version>","pc":"<PC name>","pcId":"<PC id>","canStart":true,"features":["library","watch","queues","shuffle","tracks","sound"]}`.
   `features` lists what the PC offers beyond the remote (see "The library and watching on the phone"); a PC from
   before them sends none. A PC that listens for phones on the home network adds where:
   `"lan":{"port":47830,"addresses":["192.168.1.20"]}` (see "On the home network").
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
 "media":true,                 // false when nothing is loaded in the player; the other playback fields are then null or absent
 "title":"Night Signal",
 "detail":"Season 2 · Episode 3 · Low Tide",
 "playing":true,
 "positionMs":1122000, "durationMs":2830000,
 "volume":64, "muted":false,
 "loop":"off|all|one",
 "shuffle":false,             // PCs whose welcome lists `shuffle`; absent from older ones
 "fullscreen":false,
 "hasPrevious":true, "hasNext":true,
 "canControl":true,            // false in a room where only whoever plays the video may control it
 "room":null,                  // or {"name":"Movie club","people":3} while the PC is in a room
 "mediaId":"<library id>",     // the library video the PC plays on its own, or null (nothing, music, or a room's video)
 "audioTracks":[{"id":1,"name":"Japanese","detail":"Stereo"}],   // PCs whose welcome lists `tracks` (see "Tracks")
 "audioTrack":1,
 "subtitleTracks":[{"id":-1,"name":"Off","detail":null},{"id":3,"name":"English","detail":"Full"}],
 "subtitleTrack":3,
 "canChangeTracks":true,
 "phoneSound":false}           // PCs whose welcome lists `sound`: true while a phone plays the PC's sound (`muted` is then the PC's own mute)
```

While playing, the phone advances the position itself from when the message arrived; the PC also sends a fresh
`state` every 5 seconds and after every seek.

`error`: `{"type":"error","code":"<short code>","message":"<sentence to show>"}` for something that couldn't be done:
`not-allowed` in a room where only the person playing the video can control it, `nothing-playing`, `not-shown`
(fullscreen while the PC isn't showing the player), `pairing` (a used or expired pairing code, or `pair` on a
paired link) and `protocol`.

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
| `shuffle` | | R (Shuffle on or off; PCs whose welcome lists `shuffle`) |
| `fullscreen` | | F |
| `audio-track` | a track's `id` from `audioTracks` | choosing it in the player's Audio menu (PCs whose welcome lists `tracks`) |
| `subtitle-track` | a track's `id` from `subtitleTracks`, -1 for Off | choosing it in the player's Subtitles menu (same) |

Commands go through the same code as the PC's keys and buttons, so a room's shared-controls rule applies to them
the same way. With `canControl` false, every action except `volume`, `mute` and `fullscreen` is refused with
`not-allowed`: those three change only this PC. The track actions follow `canChangeTracks` instead.

### Tracks

A PC whose welcome lists `tracks` puts its player's Audio and Subtitles menus in the `state`: `audioTracks` and
`subtitleTracks` list the menus' choices in their order, each with the `name` the menu leads with (usually the
language) and the muted `detail` under it, or null. Off is the choice with id -1, first in `subtitleTracks` (and
in `audioTracks` when the player offers no audio as a choice). `audioTrack` and
`subtitleTrack` are the ticked ids, or null when the menu has none ticked. The lists are the player's menus as they
are: empty before the first video has opened, and still the previous video's for a moment while the next one opens.
Ids are the player's own and last only for the loaded video.

`audio-track` and `subtitle-track` choose as a click in the menu does: an audio track also switches the subtitles to
the PC's rule for its language, and in a room the choice is the room's, for everyone. `canChangeTracks` is false where
the menus are greyed out: while the player stops a video, and in a room also for everyone but whoever plays the video
unless controls are shared, while the room's video loads or the room reconnects, and for a guest watching a converted
stream. A track command is then refused with `not-allowed`, whose message says which. An id the menu doesn't have is
ignored. The PC sends a fresh `state` after every track command, also one that changed nothing.

Unknown message types and actions are ignored, so either side can add new ones within version 1. Changing the
meaning of an existing message needs version 2.

## The library and watching on the phone

A PC whose welcome lists `library` answers `browse`; one that lists `watch` also streams videos to the phone and takes
them back. All of these messages travel on `remote-v1`, except the video and picture bytes, which use a second data
channel the phone opens beside it.

### Browsing

Phone → PC: `{"type":"browse","request":<n>,"home":false,"category":0,"query":"","parentId":null,"season":null,"page":0,"seed":0}`.
`category` is 0 for all videos, 1 films, 2 shows, 3 anime, 6 music. `parentId` with a show's entry id lists its
seasons; with a `season` as well, that season's episodes. `home` true lists Home instead: Continue watching, then
suggestions for each kind (shuffled by `seed`), then one random pick.

PC → phone:

```json
{"type":"page","request":7,"total":53,"page":0,"pageSize":40,"location":"All titles",
 "entries":[{"id":"…","title":"Night Signal","caption":"Show · 2021","level":"series|season|episode|movie",
   "season":null,"episode":null,"overview":"…","kind":"Movie|Show|Anime|Music","runtimeMinutes":48,"year":2021,
   "episodes":10,"homeSection":"continue|suggestions|mystery|null","positionMs":0,"watched":false,
   "artwork":"<token or null>","playable":false}]}
```

`playable` entries are files the phone can watch or start on the PC: films, episodes, and Continue watching entries
(which name the episode to resume even when their level is `series`). `positionMs` and `watched` are the PC's own
resume point and watched mark. A failure is an `error` with code `browse` and the `request`.

BlackPearl's window starts the phone remote before it has read its library. After 0.3.144 a library request (`browse`,
`queues`, `watch`, `play`, `progress`) that arrives meanwhile waits for it, up to 15 seconds, and past that is an
`error` with code `loading` and the `request` (a `progress` is dropped). Earlier PCs answered from an empty library,
so a phone that connected that early got an empty Home; the phone loads an empty list again whenever the link comes
back.

### Watching on the phone

Phone → PC: `{"type":"watch","request":<n>,"id":"<entry id>","quality":"auto|original|1080p|720p|480p","network":"home|away|relayed","takeOver":false,"audio":null}`.
`auto` plays the file itself on the home network and a 720p conversion elsewhere. `takeOver` true, for the video in
the PC's `mediaId`, makes the PC save where it is and close its player, so the phone continues it. Nothing is left
loaded on the PC for its Play, a media key or the remote's `play` to start again; the PC's empty player says the video
went on to the phone.

PC → phone, for the file itself:

```json
{"type":"stream","request":3,"id":"…","title":"Night Signal","detail":"Season 2 · Episode 3","positionMs":1122000,
 "durationMs":2830000,"kind":"file","resource":"file/<id>","length":1834567890,"extension":".mkv",
 "quality":"original","qualities":["original","1080p","720p","480p"],"note":null}
```

or for a conversion (H.264 and AAC in MPEG-TS pieces of `segmentMs`, the last one shorter):

```json
{"type":"stream","request":3,"id":"…","title":"…","detail":null,"positionMs":0,"durationMs":2830000,"kind":"hls",
 "streamId":"<32 hex>","segments":708,"segmentMs":4000,"quality":"720p","qualities":["original","720p","480p"],"note":null,
 "audioTracks":[{"index":0,"language":"jpn","title":null,"codec":"eac3","layout":"5.1(side)"},
                {"index":1,"language":"eng","title":"Commentary","codec":"aac","layout":"stereo"}],"audioTrack":0}
```

A conversion carries one of the file's audio tracks. `audioTracks` lists them all in the file's order, with the
language tag and title the file gives them (null when it gives none). A track whose file names no language (Matroska
players call it English) has the language the PC identified while it played, as a two-letter code, or null. `audioTrack` is the `index` of the one the
conversion carries, or null for a video with no sound. `watch` takes `"audio":<index>` to convert with that track, as
the phone asks when its Audio menu changes the track of a conversion, or keeps it for another quality. Without one,
or with an index the file doesn't have, the PC starts with the track its own player would: the first language of
Settings › Playback that a track has, else the track the file marks as default, else the first. Before 0.3.143 a
conversion had no sound, and the answer listed no tracks.

Both also carry, for an episode, the episodes the PC's own Previous and Next would play and the show's first episode,
which Loop all starts again from after the last one, each as `{"id":"…","title":"…","detail":"Season 2 · Episode 4"}`
or null (`previous`, `next`, `first`; `first` only when there is no `next`), and the PC's track preferences from
Settings › Playback, as two-letter language codes in priority order: `"tracks":{"audio":["ja","en"],"subtitles":["en"],
"rules":[{"audio":"en","languages":["off"]}]}`. A rule replaces `subtitles` while the audio is in its language; `off`
means no subtitles. The phone picks its starting tracks with them as the PC would. Older PCs send none of these.

`positionMs` is where to start: the PC's saved position, 0 for a watched video. `note` says why the phone got the
file when it asked for a conversion (no converter, or a file already smaller). The PC keeps one stream per phone; a
new `watch` replaces it and `{"type":"stream-stop"}` ends it. A failure is an `error` with the `request` and the code
`gone` (not in the library, or its drive is disconnected).

Phone → PC while watching, every 10 seconds, on pause, and when it stops:
`{"type":"progress","id":"…","positionMs":1180000,"durationMs":2830000,"ended":false,"final":false}`. The PC saves it
as its own playback: the resume point, when it was last played, and the watched mark once the position is within
2 seconds of the end, or `ended` is true within the last minute (or anywhere, when `durationMs` is 0). `final` is true for the last report of a viewing. A `final` report in the last tenth of the video, as when Next skips the credits, also marks it watched, as the PC's "Next episode" button does. The PC ignores reports for
the video it is playing itself at that moment.

### Continuing on the PC

Phone → PC: `{"type":"play","request":<n>,"id":"…","positionMs":1180000}` plays the video on the PC from that
position, and answers `{"type":"done","request":<n>}` once it has started. It needs `canStart`; a refusal is an
`error` with code `not-allowed`, `in-room` (the PC is in a room), `gone`, or `opening` (BlackPearl is starting on the PC: ask again once the phone has reconnected to it). The PC ends the phone's stream before it
answers: the phone is no longer watching, and an answer queued behind video it still reads can take seconds to arrive.

### Queues

The PC's saved queues, the ones on its Queues page, are shared with the phone when its `welcome` lists the `queues` feature. A video's place is its position in the
saved queue (from 0), so a video queued twice has two places; videos the library no longer has keep their places but
are never listed.

Phone → PC: `{"type":"queues","request":<n>}`. PC → phone:
`{"type":"queues","request":<n>,"queues":[{"id":"…","name":"Evening","count":12,"upNext":3,"active":true,"artwork":"<token>"}]}`.
`count` is the videos the library has; `upNext` is the place Play continues from, as on the PC's Queues page (the
queue's place when it is the PC's active one, otherwise its first unwatched video), or null; `active` marks the queue
the PC's player uses.

`browse` with `"queue":"<id>"` answers a `page` of that queue's videos in order, and with `"episodesOf":"<entry id>"`
the show's episodes, in the order its Previous and Next follow. Their entries are the usual ones plus `"index"`, the
place (for `episodesOf`, the position in the list). A queue that is gone is an `error` with code `browse`.

`watch` and `play` take `"queue":"<id>","queueIndex":<place>`. The video plays as part of that queue: for `watch`, the
answer's `previous`, `next` and `first` are the queue's playable videos around the place (each with a `queueIndex`),
and `"queue":{"id":"…","name":"…","index":<place>}` echoes it. A place that no longer holds the video falls back to the
video's first place, and a queue that doesn't have it to the show's episodes. On the PC, `play` makes the queue its
player's, as playing it there does; with BlackPearl closed, the phone host saves it so BlackPearl opens on it.

The `state` carries `"queue":{"id":"…","name":"…","index":<place>}` while the PC plays a video from a saved queue (not
in a room), or null.

### The media channel, `media-v1`

The phone opens a second data channel labelled `media-v1`, reliable and ordered, with the first. A PC that doesn't
know it closes it. The phone asks with text messages:

`{"type":"read","id":<u32>,"resource":"<resource>","offset":<bytes>,"count":<1 to 262144>}`, and
`{"type":"cancel","id":<u32>}` for a read it no longer needs.

Resources: `file/<id>` (the video of the phone's current `file` stream), `stream/<stream id>/<piece>` (a piece of
its current conversion) and `art/<token>/<width>` (an entry's picture as JPEG, at most `width` pixels wide, 64 to
1280, never enlarged). A token names the same picture in every BlackPearl process on the PC: after 0.3.144, one handed
out by the phone host still works once the app has taken over, and the other way round. The phone asks again for a
picture that didn't come, a few times, further apart each time.

The PC answers reads in the order they were asked, each as binary frames of at most 16 KiB of data after a 24-byte
little-endian header:

| bytes | field |
| --- | --- |
| 0–3 | read id (u32) |
| 4–7 | offset of this frame's data in the reply (i32) |
| 8–11 | the reply's length (i32); shorter than `count` at the end of the resource, 0 past it |
| 12–15 | reserved, 0 |
| 16–23 | the whole resource's length (i64) |

A read that can't be answered gets a text `{"type":"read-error","id":<u32>,"code":"busy|gone|invalid|failed","message":"…"}`.
`busy` means not ready yet (a piece still converting): ask again shortly. The PC queues at most 64 reads per phone and
answers `busy` past that.

## Sound on the phone

A PC whose welcome lists `sound` plays the sound of what it plays on the phone instead, while its picture stays on the
PC: headphones on the couch. The PC goes quiet (as muted, without changing its own mute) while any phone has the sound,
and its Mute button, M or a phone's `mute` command brings the sound back to the PC.

Phone → PC: `{"type":"listen","request":<n>,"on":true}` (or `false` to give the sound back). The PC answers
`{"type":"listen","request":<n>,"on":true}`, or an `error` with the `request`: `in-room` (not while the PC is in a room).
It then sends, unasked, what to play whenever that changes (another video, another audio track, nothing playing):

```json
{"type":"sound","on":true,"stream":{"streamId":"<32 hex>","source":"<16 hex>","segments":708,"segmentMs":4000,"durationMs":2830000},"why":null}
```

`stream` is the sound of the PC's current video in its current audio track, as AAC in MPEG-TS pieces of `segmentMs`,
read on `media-v1` as `stream/<streamId>/<piece>` like a conversion, and on the video's own clock (piece 0 starts at
0:00). It is null while there is nothing to play, with `why` saying why when it isn't simply that nothing plays
(`"The PC's audio is turned off for this video."`, `"This video has no sound."`). `{"type":"sound","on":false,"why":"…"}` means the PC took the sound
back (its Mute, or it couldn't convert the sound); the phone stops and says why.

The phone follows the picture by asking where the player is, about once a second:
`{"type":"clock","request":<n>}` → `{"type":"clock","request":<n>,"source":"<16 hex or null>","positionMs":1122340,"playing":true}`.
The PC answers at once from the thread that received it, with the position of the picture on screen (libVLC's
position less the 60 ms it runs ahead of its output), so the phone can take half the round trip as the answer's time on
the way. `source` names the video, as `stream.source` does: an answer about another video means its sound is on the way.
The phone plays a few percent faster or slower to close a small gap and seeks for one over 200 ms; its user can move
the sound later or earlier for headphones that take their own time.

A phone that stops asking for 10 seconds (its link dropped included) is taken to be gone, and the PC plays its sound
again. A phone that comes back asks with `listen` again. Joining or hosting a room gives the sound back to the PC
(`{"type":"sound","on":false,"why":"Sound on the phone isn't available in a room."}`).

## While BlackPearl is closed

With **Phones can browse and watch while BlackPearl is closed** on (Settings › Profile › Phone remote, on by default),
BlackPearl starts a small process of itself with no window, `BlackPearl.exe --phone-host`, once it has closed, and
optionally at Windows sign-in (`--phone-host --signed-in`, from a `Run` entry named `BlackPearl phone access`). It
connects for phones with the same key, so to a phone it is the same PC: its `welcome` offers `library` and `watch`,
its state says nothing is playing, and the remote's commands get `error` `nothing-playing`. Browsing, watching and
progress work as with the app. Continuing on the PC opens BlackPearl with the video (`--play-id <id>`), which plays it
from the position the host saved once its library has loaded.

The host shows an icon in the notification area whose menu opens BlackPearl or turns the host off. It ends once
BlackPearl has the library open again: after the room server has handed the PC's id to the app (at most ten seconds),
so phones are never left with neither. The phones then reconnect to the app as after any dropped link. BlackPearl
doesn't start the host when it closes to install an update or as Windows signs out, and a build started with
`BLACKPEARL_PHONE_HOST=off` (as `scripts/dev-launch.ps1` does unless `-PhoneHost`) never starts it or changes the
sign-in entry.

## On the home network

When the room server can't introduce a phone to its PC (the server or the internet is down, or the server says the PC is
offline because the PC has lost its internet), a phone on the same network as the PC can still reach it. PCs after
0.3.146 listen for phones on a port of their own and speak the room server's `/remote` protocol there, for their own PC
id only. Nothing on it is trusted more than the room server is: the same signed signals, checked the same way.

**Where.** TCP port 47830, or, when another program has it, the next free one up to 47839. The PC tries the port it used
last first. Its `welcome` (see "Opening") says where it listens: `"lan":{"port":47830,"addresses":["192.168.1.20"]}`, its
IPv4 addresses on adapters that are up, those with a gateway on wired or wireless adapters first, at most eight. `lan` is
left out while the PC isn't listening (every port taken, or one BlackPearl process handing the port to the other), and a
phone then keeps what it knew. The phone stores it per PC and replaces it from every `welcome` that has one. There is no
discovery: a PC whose address changed while the room server was down is found again once the server is back.

**The socket.** `ws://<address>:<port>/remote`, a plain WebSocket. As with the room server, the socket isn't trusted;
the signals are signed. The phone sends `{"type":"remote-phone","target":"<PC id>","number":1}`, and the PC answers
`{"type":"remote-welcome","target":"<this connection's id>","data":"{\"iceServers\":[],\"forceRelay\":false,\"session\":\"<32 hex>\"}"}`
and `{"type":"remote-online"}` at once. A target that isn't this PC's id gets `{"type":"error","text":"This is another PC."}`
and the connection closes, and a `number` other than 1 an error saying which side to update. Then `signal` goes both
ways as through the room server (the PC's carry no `sender`), and `ping` is answered with `pong`. There is never a
`remote-offline`. Any other HTTP request is answered 404.

**Its session.** Anyone on the network can see what the socket carries, and a signature says nothing about when it was
made, so each connection hands its phone the session id to use: `session` in its `remote-welcome`. The phone's offer on
that socket uses it, once (a second offer on the same socket gets a session id of its own, and is refused). The PC takes
on that connection only signals of that session: offers and candidates seen elsewhere and sent again carry another
session id and are ignored. The id is 8 random bytes followed by the first 8 bytes of HMAC-SHA256, keyed with the UTF-8
bytes of the host key, over `bp-remote-lan\n` and those 8 bytes, as 32 lower-case hex characters. Only the PC can make
one, and it knows one when it sees one: through the room server, the PC refuses an offer under such a session id, also
after a restart. Through the room server it also refuses an offer under a session id it has already seen from that
phone (or pairing code) since it started; the phone makes a new one for every attempt.

On this path neither side uses STUN or TURN servers: ICE finds the direct path with the two devices' own addresses. The
phone ignores `iceServers` and `forceRelay` from this socket's unsigned welcome, so whatever answers at the address can't
choose its relay or force one. A room server's `forceRelay` can't be kept without a relay; the PC's log notes
`relayIgnored`.

**Limits.** At most 8 connections, and at most 4 from one address that haven't proved themselves. A connection proves
itself with a signal of its handed-out session that verifies with a phone's secret or the live pairing code, and that
opens a session or belongs to the live one. When full, the longest-waiting unproven connection of the address holding
the most makes room; when every one has proved itself, the new one is closed. A phone keeps one proven connection: its
newer one replaces the older. The HTTP request is at most 8 KiB, and it and `remote-phone` must arrive within 10
seconds. Messages are at most 64 KiB, at the room server's rate for phones (bursts of 120, 60 a second). A connection
that hasn't proved itself within 30 seconds is closed, and none lasts more than 6 hours.

**Which path the phone takes.** The room server first, always. The phone tries the home network when it has an address
for the PC and the room server can't be reached, refuses the connection, closes it before the link is up, or says the PC
is offline (then again while it waits). It tries only while on Wi-Fi or Ethernet, and on Android opens those sockets on
the Wi-Fi even when Android has made mobile data the default because the Wi-Fi has no internet. It connects to every
address at once and keeps the first that greets it as the right PC within 4 seconds; when none does, it shows the room
server's failure as before. After a try that found nothing it waits 20 seconds before the next, then twice as long each
time up to 5 minutes, whatever the room server does meanwhile; a network change, the app coming back to the screen, or
Try again start that over. Once the link is up, which path introduced it doesn't matter, and the next attempt starts with
the room server again. Pairing uses the room server only: a pairing code comes with the server's address and nothing
else.

**Firewall.** Windows asks once, when BlackPearl first listens, whether to let it accept connections; its installer is
per-user and can't add a rule. The phone host is the same program, so the same answer covers it. Settings › Profile ›
Phone remote reads Windows Firewall's settings and rules for BlackPearl, without changing them, and says whether they
let phones in on the network the PC is on, and how to allow it when they don't. It can't see other firewalls' rules,
and says so when Windows lists one.

**Handing over.** One BlackPearl process of a library listens at a time, the one that also holds its room server
connection (see "While BlackPearl is closed"). BlackPearl lets go of the port as it closes, before it starts the phone
host, and the phone host as it ends. The process taking over waits for the port, up to 30 seconds, rather than moving
to another, so phones find it where they knew it. A phone's link drops as they hand over, as it does through the room
server, and the phone reconnects.

**Older versions.** PCs up to 0.3.146 don't listen and send no `lan`. A phone that knows no address for a PC never tries
the home network, so with those PCs, and with PCs it hasn't connected to since they gained this, it behaves as before.
BlackPearl Mobile up to 0.8.2 ignores `lan` and connects only through the room server.

Development builds started with `BLACKPEARL_PHONE_LAN=off` don't listen; with `=loopback` (as `scripts/dev-launch.ps1`
starts them unless `-PhoneLan`, and as the checks do) they listen on 127.0.0.1 only and say so in `lan`: a build in a
new folder listening on the network would raise Windows Firewall's question each time.

## Diagnostics

The PC writes the phone remote's progress to its diagnostics log, `logs/diagnostics.jsonl` in the app's data folder
(`logs/phone-host/` for the phone host), so a phone that couldn't connect can be traced afterwards. Records name a
session and a phone by the first 8 characters of their random ids, and never hold keys, secrets or pairing codes.

| Kind | When |
| --- | --- |
| `remote-start`, `remote-stop`, `remote-off` | The link to the room server starts or stops, or the phone remote is turned off |
| `remote-server` | The room server link changes state: `ready` (with the attempts that failed before it), `lost`, `unreachable` (with the error), `refused`, `replaced`, `outdated-server`, `invalid-address`. A state that repeats is written once. |
| `remote-signal-refused` | A signal the PC turned away, once per session and reason: `unknown-phone`, `pairing-expired`, `bad-signature`, `too-many-sessions`, and for signals sent again `wrong-session` (on the home network, not the session its connection handed out), `lan-session` (through the room server, a session handed out on the home network), `repeated-offer` (an offer seen before) |
| `remote-session-opened` | A phone's offer starts a session: whether it pairs, replaces an earlier session, how many STUN and TURN servers it may use, and `via` (`server` or `lan`), with `relayIgnored` on the home network when the room server asks for relay only |
| `remote-session-state` | The connection's state changes, with the candidates gathered on each side by type, and `direct` or `relay` once connected |
| `remote-session-channel`, `remote-session-greeted`, `remote-session-paired` | The data channel opens, the phone's `hello` is accepted (with its app version), pairing completes |
| `remote-session-refused` | `protocol` (with the phone's protocol), `pairing-expired`, `already-paired` |
| `remote-session-closed` | Once per session, with the first reason (`failed`, `disconnected`, `closed`, `channel-closed`, `replaced`, `removed`, `protocol`, `unreadable-offer`, `stopped`), its age, its path, and `via` |
| `remote-lan` | The home-network listener: `started` (its port, whether it moved from the one it tried first, `any` or `loopback`, how many addresses it gives phones), `waiting` (for the other BlackPearl process to let go of the port), `busy` (every port taken), `stopped`; `opened` and `closed` for each connection (a short random id, the reason, whether it proved itself); `refused`, once per reason a minute (`too-many-connections`, `too-many-from-address`, `bad-request`, `wrong-pc`, `protocol`, `too-large`, `rate`, `unproven`), with `evicted` and `superseded` among the reasons connections close; `port-not-saved` when the port couldn't be remembered; and `firewall` when what Windows Firewall decided changes (`allowed`, `off`, `blocked`, `undecided`, `unknown`, the network's category, and other firewalls Windows lists). No addresses. |
| `phone-read-failed`, `phone-resource-missing` | A read on `media-v1` failed, with the kind of resource; and why the PC had nothing for it (`no-video`, `other-video`, `not-converted`, `other-stream`, `no-such-piece`, `no-such-sound-piece`, `unknown-picture`, `missing-file`, `unreadable:<error>`, `malformed`) |
