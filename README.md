# BlackPearl Mobile

A phone remote for [BlackPearl](https://github.com/Svovoniks/BlackPearl): control playback and pick what to watch on your PC, at home or away.

The app talks to the desktop app over the protocol in [PHONE-REMOTE.md](PHONE-REMOTE.md).

## What it does

- **Pairing.** On the PC, open Settings › Phone remote. Scan its code with the app (or with the phone's camera, which
  opens the app), or paste the link it shows. The phone keeps its own key in the platform's secure storage. Several
  PCs can be paired; tap the PC's name at the top to switch, pair another or forget one.
- **Connecting.** The room server introduces the phone and the PC and hands out STUN/TURN servers; every signaling
  message is signed with the key only the two of them know. Commands and state then travel on a direct WebRTC data
  channel, on the home network or across the internet ("away"), through the TURN relay when nothing direct works. The
  app reconnects by itself when the link drops, when it comes back to the foreground and when the network changes.
- **Remote.** Play and pause, ±10 s, previous and next, stop, loop (off, all, one), the timeline, the PC's volume and
  mute, fullscreen, and the PC player's Audio and Subtitles: their sheet lists the PC's tracks as its menus show them,
  and picking one there is a click in the PC's menu. In a room where only whoever plays the video picks tracks, the
  sheet shows them without changing them. The artwork area is a touch pad: tap to play or pause, swipe sideways to skip
  10 s, slide up and down for volume. Under the play buttons, one row holds Audio, Subtitles and Sound and the next
  Shuffle, Loop, Up next, Fullscreen and Stop; the volume stays above the tab bar while the rest scrolls on a short
  phone. While nothing plays, the Remote leads to the Library and lists the PC's Continue watching, where a card
  starts on the PC with one tap, and after Stop it offers the stopped video again from where it was. On the other
  tabs, and on the pages that cover them, a bar at the bottom shows what the PC plays with −10 s, Play/Pause and
  +10 s; its title opens the Remote.
  **Sound**, beside Audio and Subtitles, plays the PC's sound on the phone while the picture stays on the PC, for
  headphones on the couch: the PC goes quiet, the phone keeps itself in step with the picture (a little faster or
  slower, or a seek for a larger gap), the volume row and touch pad set the phone's volume, and − and + (on a row
  under it while it is on) move the
  sound 50 ms earlier or later for headphones that lag. It keeps playing with the screen off (the background service
  runs while it plays, even with Stay connected in the background off; Disconnect stops it). The PC's Mute, or joining a
  room, takes it back.
  When the PC plays a video of its own library, **Watch here** moves it to the phone: the PC stops and the phone carries
  on from the same moment.
- **Library.** The PC's Home (Continue watching, the titles not started yet newest first with See all, suggestions for
  each kind, a random pick), films, shows and anime as posters, chosen with the section button at the bottom corner,
  search in a tab of its own, and a show's
  seasons and episodes, with the PC's
  resume points and watched marks. A title's sheet plays it on the phone (resume or start over) or on the PC, and marks
  it watched or unwatched; a show's or a season's page marks all its episodes. A long press on a title offers the same
  without opening it, and an episode's row has a play button that starts it where a video was last started, on the
  phone or on the PC.
- **Watching on the phone.** The PC sends the video over the same direct link; the phone plays it with libmpv
  (media_kit) through a small HTTP server on `127.0.0.1` that turns the player's byte ranges into reads on the link's
  `media-v1` channel. At home the phone gets the file itself; away from home it asks for a 720p conversion by default
  (Settings › Quality away from home; the player's tune button changes it for one video). The phone reports where it is
  every 10 seconds, when it pauses and when it stops, so the PC's Continue watching and watched marks follow.
  **Continue on PC** hands the video back: the PC plays it from where the phone was.
- **The player.** Play and pause, back and forward 10 s (or double-tap a side), and for an episode Previous and Next,
  which step through the show as the PC's buttons do (Previous goes back to the start after 3 seconds). When an episode
  ends, an up-next card plays the next one after 15 seconds unless canceled. Loop cycles off, all (a show starts again
  after its last episode) and one, and is remembered. The tune button opens Audio, Subtitles and Quality: beside the
  video in landscape, a short sheet in portrait. Tracks are named by language, with what tells them apart, and start as
  the PC's Settings › Playback languages would pick them. Another quality, a recovery or the next episode opens on the
  player already on screen, which shows what it is waiting for. Each video opens in its own shape, sideways for a wide
  one and upright for a tall one (from the size its file gives, turned and stretched as the file says), and keeps it
  however the phone is held; Settings › Turn the player with the phone makes the player turn with the phone instead.
- **Queues.** The PC's saved queues (its Queues page) are in the Library's Queues section: each opens its videos in order, with Play
  on the phone or on the PC from where it continues. A video played from a queue steps through the queue: Previous,
  Next, the up-next card and Loop all follow it, on the phone and on the PC. The player's Up next page lists the show's
  episodes or a queue and switches between them, as the PC's queue menu does, and the Remote tab's Up next lists what
  the PC plays through, to start another video of it there. While the phone waits for an answer from the PC, the player
  holds back its next reads for a few seconds, so the answer isn't queued behind more video.
- **Picture in picture (Android).** While a video plays, leaving the app (Home, or switching apps) moves it to a small
  window with Play/Pause; the player's picture-in-picture button does it at once. A video left without picture in
  picture (paused, or on a phone that doesn't allow it) waits, and carries on when the app is back. Back from the small
  window, the video has the shape it had; a player that turns with the phone keeps it until the phone is turned to
  match.
- **Background connection (Android).** With Settings › Stay connected in the background on (the default), closing the
  app leaves a foreground service running that keeps the link to the PC. Its notification says how the connection is,
  with a Disconnect button that drops the link until the app is opened again, without changing the setting. While the
  PC plays a video the phone can control, the notification is a media one (`RemoteSession.kt`, a media session of the
  platform's own, with no added library): the lock screen and Android's media controls show the video with a timeline,
  Play/Pause, back and forward 10 s, Next and Disconnect, and with Settings › Volume buttons set the PC's volume on
  (the default) the phone's volume buttons change the PC's volume while it plays, as for a cast. They stay the
  phone's own while the phone plays the PC's sound or a video itself. Headset buttons reach the session only when the
  app has played sound on the phone, which is Android's rule for them. The Flutter engine lives apart from the activity
  (`LinkEngine`), so opening the app again shows it already connected.

## Building

Flutter stable (see `FLUTTER_VERSION` in `.github/workflows/build.yml`).

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

The link to the PC runs on [libdatachannel](https://github.com/paullouisageneau/libdatachannel), as the desktop app's
side does, with data channels only and Mbed TLS: `packages/blackpearl_datachannel` builds it from source with each
platform's toolchain (the NDK and its CMake on Android), downloading the pinned sources the first time each ABI is
built. A debug APK builds it for every ABI, so the first debug build takes a few minutes longer.

Scanning the pairing code uses the barcode scanner of Google Play services rather than a copy of ML Kit in the APK
(`android/gradle.properties`). On a phone without Play services the camera can't read the code; pasting the link on
the pairing screen still works.

Release APKs are built and signed by CI when a `v*` tag is pushed, and attached to that tag's GitHub release: one per
ABI, `BlackPearl-v<version>.apk` for 64-bit ARM (nearly every phone) and `BlackPearl-v<version>-armeabi-v7a.apk` for
32-bit ARM. None is built for x86_64. Their native libraries are compressed, which halves the download; Android unpacks
them on install. Since the split, Flutter numbers each APK's version code as 1000 × the ABI's number + the build number
(armeabi-v7a 1, arm64-v8a 2), so later releases must stay split for phones to accept them as updates. The tag
must match `version:` in `pubspec.yaml`. Signing uses the repository secrets `ANDROID_KEYSTORE_BASE64`,
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`. A local `flutter build apk --release`
without `android/key.properties` is signed with the debug key, so it can't update an installed release. Releases are
shipped through a reviewed pull request with `scripts/ship.ps1`, which picks the version, tags the merge and verifies
the published APKs: see UPDATES.md.

### Crash reports

Release APKs send errors, crashes and timings to Sentry, unless Settings › Send crash reports is off: app start,
`playback.open` (from asking to play a video until the player shows it), and the link to the PC
(`lib/diagnostics/link_reports.dart`, PHONE-REMOTE.md "Measuring the link"). `remote.connect` times setting a link up,
stage by stage, and `remote.link` a stretch of a link that is up (at most 10 minutes, or until it ends): round trips of
the phone's pings, unanswered pings, bytes and reads on `media-v1`, how fast they arrived while reads were in flight, and
how long a read with none ahead of it waited for its first frame. They carry fixed codes, the path's kind, numbers and
the PC app's version, never an id, a name, an address or what was read. A failed setup goes once per reason a half hour,
and a stretch with no video read in it (a phone left connected in the background) once an hour. Only a build given
`--dart-define=SENTRY_DSN=<dsn>` starts Sentry; CI passes the repository secret `SENTRY_DSN`, and local builds and
tests send nothing. `--dart-define=SENTRY_ENVIRONMENT=<name>` (default `production`) names the environment; outside
production every transaction is sent, in production one in ten, except the link's timings, which all go. There are no
screenshots, replays, Sentry logs or sessions, the user, device and server names are cleared, and `lib/diagnostics/report_text.dart` replaces paths, web and
network addresses and long ids in error messages, with the desktop app's rules. Android's native crashes (Java and NDK)
are sent by Sentry's Android SDK and don't pass through that scrubbing. That SDK names the user and the device with an
id it keeps per installation, so before Sentry starts, `LinkEngine.kt` sets that id to the same zeros on every phone.

The only breadcrumbs are the app's log (`lib/diagnostics/trail.dart`): the last 100 notes the app wrote itself about
connecting to the PC, opening videos and updating, in fixed words and codes, never a title, name, address or anything
the PC or a server said. Sentry's automatic breadcrumbs (web requests, screens, taps, the console, Android's own) are
off (`AndroidManifest.xml` turns off the Android SDK's network breadcrumbs, which its other switches leave on), and
anything other than the app's categories is dropped. The notes are scrubbed again with the rules above before an error
goes, and timings carry none; Sentry also copies them to the Android SDK, so its native crashes carry them too. The log
also sends three kinds of warning that aren't crashes: a link to the PC that has failed three times in a row, or for
good (a removed phone, an expired code and a phone without internet aren't reported); a request the PC doesn't answer;
and an update that fails. Each goes by a fixed code, at most once every half hour, and twenty a run at most. Settings › Send the app's log turns
all of it off, and clears the notes kept so far; it only works while crash reports are on.

R8 renames the release build's Java and Kotlin classes. Sentry's Gradle plugin (`android/app/build.gradle.kts`) writes
a mapping id into each release APK, which the Android SDK sends with its crashes, and when `SENTRY_AUTH_TOKEN` is set
(CI's tag build passes the repository secret, an organization token) uploads the R8 mapping under that id, so those
crashes show the real class and method names. Without the token, a release build only writes the id. The plugin's other
features (added integrations, bytecode instrumentation, source and native symbol uploads, telemetry) are turned off.

Installed releases update themselves from those GitHub releases. On start, and on return after six hours, the app asks
GitHub for the latest release, and Settings › Check for updates asks right away. When it is newer, a banner offers it. The app downloads the APK, checks its size and the
SHA-256 GitHub lists for it, and hands it to Android's installer. Android asks the user once to let the app install
apps, and again to confirm each update. It installs only an APK signed with the same key. Debug builds don't check.

### Windows

The Windows target exists only so the app can be run and looked at on a PC while developing; it has no camera
scanner. Debug builds accept `--preview=<screen>` to show a screen with made-up state and no network:

```sh
flutter run -d windows -a --preview=remote
```

Screens: `remote`, `away`, `relay`, `cant-control`, `nothing`, `waiting`, `connecting`, `failed`, `removed`,
`reconnecting`, `long`, the Remote tab's tracks sheet `tracks-audio`, `tracks-subtitles`, `tracks-locked` and
`tracks-empty`, `pairing`, `pairing-error`, `chooser`, `settings`, and the update banner's `update-available`,
`update-permission`, `update-downloading`, `update-ready` and `update-failed`. Release builds ignore the flag.

`--preview=loopback` runs the real app against a room server and a stand-in PC inside the same process: it pairs,
sets up the WebRTC link with libdatachannel on both ends, and the stand-in answers commands with a made-up state.
`--loopback-log=<file>` writes each connection change and the commands the stand-in received. It follows
PHONE-REMOTE.md but is not the desktop app.

`tool/standin-pc` is a fuller stand-in that runs outside the app, in Node.js: a room server and a PC with a made-up
library that plays a real video file over `media-v1`, queues, watched marks and the home-network socket. A normal
build on the Android emulator pairs with it through the link it prints. See `tool/standin-pc/README.md`.

`--paired-pc=<JSON>` starts already paired with a real PC, for trying the Windows build against the desktop app: the
JSON is a paired PC as the app stores it, `{"pcId":…,"name":…,"server":…,"phoneId":…,"secret":…}`, with a phone id and
secret the PC knows (its `phoneRemotePhones` setting).

Building for Windows needs symlinks for plugins. Without Developer Mode, run `tool/link-windows-plugins.ps1` after
`flutter pub get`; it makes directory junctions instead. flutter_secure_storage's Windows plugin needs Visual Studio's
ATL component, so `pubspec.yaml` overrides it with `tool/windows_secure_storage_stub`, which keeps values in memory.
Neither affects Android.

## Fonts

Titles use [Source Serif 4](https://github.com/adobe-fonts/source-serif), bundled under the SIL Open Font License
(`assets/fonts/OFL.txt`).
