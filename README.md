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
  mute, and fullscreen. The artwork area is a touch pad: tap to play or pause, swipe sideways to skip 10 s, slide up
  and down for volume.
  When the PC plays a video of its own library, **Watch here** moves it to the phone: the PC stops and the phone carries
  on from the same moment.
- **Library.** The PC's Home (Continue watching, suggestions for each kind, a random pick), films, shows and anime as
  posters, search, and a show's seasons and episodes, with the PC's resume points and watched marks. A title's sheet plays
  it on the phone (resume or start over) or on the PC.
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
  player already on screen, which shows what it is waiting for.
- **Queues.** The PC's saved queues (its Queues page) are in Library › Queues: each opens its videos in order, with Play
  on the phone or on the PC from where it continues. A video played from a queue steps through the queue: Previous,
  Next, the up-next card and Loop all follow it, on the phone and on the PC. The player's Up next page lists the show's
  episodes or a queue and switches between them, as the PC's queue menu does, and the Remote tab's Up next lists what
  the PC plays through, to start another video of it there. While the phone waits for an answer from the PC, the player
  holds back its next reads for a few seconds, so the answer isn't queued behind more video.
- **Picture in picture (Android).** While a video plays, leaving the app (Home, or switching apps) moves it to a small
  window with Play/Pause; the player's picture-in-picture button does it at once. A video left without picture in
  picture (paused, or on a phone that doesn't allow it) waits, and carries on when the app is back.
- **Background connection (Android).** With Settings › Stay connected in the background on (the default), closing the
  app leaves a foreground service running that keeps the link to the PC. Its notification shows what the PC plays,
  with Play/Pause, and a Turn off button that switches the setting off. The Flutter engine lives apart from the activity
  (`LinkEngine`), so opening the app again shows it already connected.

## Building

Flutter stable (see `FLUTTER_VERSION` in `.github/workflows/build.yml`).

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Release APKs are built and signed by CI when a `v*` tag is pushed, and attached to that tag's GitHub release. The tag
must match `version:` in `pubspec.yaml`. Signing uses the repository secrets `ANDROID_KEYSTORE_BASE64`,
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`. A local `flutter build apk --release`
without `android/key.properties` is signed with the debug key, so it can't update an installed release.

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
`reconnecting`, `long`, `pairing`, `pairing-error`, `chooser`, and the update banner's `update-available`,
`update-permission`, `update-downloading`, `update-ready` and `update-failed`. Release builds ignore the flag.

`--preview=loopback` runs the real app against a room server and a stand-in PC inside the same process: it pairs,
sets up the WebRTC link with flutter_webrtc on both ends, and the stand-in answers commands with a made-up state.
`--loopback-log=<file>` writes each connection change and the commands the stand-in received. It follows
PHONE-REMOTE.md but is not the desktop app.

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
