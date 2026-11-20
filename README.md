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

### Windows

The Windows target exists only so the app can be run and looked at on a PC while developing; it has no camera
scanner. Debug builds accept `--preview=<screen>` to show a screen with made-up state and no network:

```sh
flutter run -d windows -a --preview=remote
```

Screens: `remote`, `away`, `relay`, `cant-control`, `nothing`, `waiting`, `connecting`, `failed`, `removed`,
`reconnecting`, `long`, `pairing`, `pairing-error`. Release builds ignore the flag.

`--preview=loopback` runs the real app against a room server and a stand-in PC inside the same process: it pairs,
sets up the WebRTC link with flutter_webrtc on both ends, and the stand-in answers commands with a made-up state.
`--loopback-log=<file>` writes each connection change and the commands the stand-in received. It follows
PHONE-REMOTE.md but is not the desktop app.

Building for Windows needs symlinks for plugins. Without Developer Mode, run `tool/link-windows-plugins.ps1` after
`flutter pub get`; it makes directory junctions instead. flutter_secure_storage's Windows plugin needs Visual Studio's
ATL component, so `pubspec.yaml` overrides it with `tool/windows_secure_storage_stub`, which keeps values in memory.
Neither affects Android.

## Fonts

Titles use [Source Serif 4](https://github.com/adobe-fonts/source-serif), bundled under the SIL Open Font License
(`assets/fonts/OFL.txt`).
