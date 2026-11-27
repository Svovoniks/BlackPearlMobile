import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../app_model.dart';
import '../background/background_link.dart';
import '../connection/remote_link.dart';
import '../storage/app_settings.dart';
import '../update/app_update.dart';
import 'home_shell.dart';
import 'pebbles.dart';
import 'theme.dart';

/// The Settings tab: the background connection, the quality away from home, how the player turns, the paired PCs, crash
/// reports, and app updates.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.model, required this.link, required this.onChoosePc, this.updater});
  final AppModel model;
  final RemoteLink link;
  final VoidCallback onChoosePc;

  /// Checks for and installs app updates; null where the app doesn't update itself.
  final AppUpdater? updater;

  @override
  Widget build(BuildContext context) {
    final settings = model.settings;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: settings,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              Text('Settings', style: display(28)),
              const SizedBox(height: 16),
              Slab(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: settings.backgroundLink,
                      onChanged: BackgroundLink.supported ? (value) => settings.setBackgroundLink(value) : null,
                      activeThumbColor: Palette.accentInk,
                      activeTrackColor: Palette.accent,
                      title: const Text('Stay connected in the background', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        BackgroundLink.supported
                            ? 'The phone keeps its connection to ${link.pcName} after you close the app, so the lock screen and '
                                  'the notification show what plays there with its play buttons, and the app opens already connected. '
                                  'Android shows the notification while this is on; its Disconnect button drops the connection until you open the app again.'
                            : 'Only BlackPearl on Android stays connected in the background.',
                        style: const TextStyle(color: Palette.muted, fontSize: 13, height: 1.35),
                      ),
                    ),
                    if (BackgroundLink.supported) ...[
                      const SizedBox(height: 6),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: settings.volumeKeys,
                        // Android gives the volume buttons to what its media controls show, which the connection above keeps there.
                        onChanged: settings.backgroundLink ? (value) => settings.setVolumeKeys(value) : null,
                        activeThumbColor: Palette.accentInk,
                        activeTrackColor: Palette.accent,
                        title: const Text("Volume buttons set the PC's volume", style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: Text(
                          "While the PC plays, the phone's volume buttons change the PC's volume, also with the screen locked. "
                          "Off, they change the phone's own. They are always the phone's while it plays the PC's sound or a video itself.",
                          style: TextStyle(color: Palette.muted, fontSize: 13, height: 1.35),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Slab(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Quality away from home', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    const Text(
                      "What the phone asks for when it isn't on the PC's network. The PC converts the video as you watch; "
                      'at home the phone plays the file itself. The player can change it for one video.',
                      style: TextStyle(color: Palette.muted, fontSize: 13, height: 1.35),
                    ),
                    const SizedBox(height: 6),
                    RadioGroup<String>(
                      groupValue: settings.awayQuality,
                      onChanged: (value) {
                        if (value != null) settings.setAwayQuality(value);
                      },
                      child: Column(
                        children: [
                          for (final quality in AppSettings.qualities)
                            RadioListTile<String>(
                              value: quality,
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              activeColor: Palette.accent,
                              title: Text(awayQualityLabel(quality), style: const TextStyle(fontSize: 14.5)),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Slab(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: settings.followPhoneRotation,
                      onChanged: (value) => settings.setFollowPhoneRotation(value),
                      activeThumbColor: Palette.accentInk,
                      activeTrackColor: Palette.accent,
                      title: const Text('Turn the player with the phone', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
                    ),
                    // The same words either way, so nothing below the switch moves under the finger.
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Text(
                        "On, the player turns as the phone does, as Android's Auto-rotate says. Off, each video opens in "
                        'its own shape, sideways for a wide video and upright for a tall one, and keeps it however you '
                        'hold the phone.',
                        style: TextStyle(color: Palette.muted, fontSize: 13, height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Slab(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Paired PCs', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(
                      'Using ${link.pcName}. Switch to another PC, pair one more, or forget one.',
                      style: const TextStyle(color: Palette.muted, fontSize: 13, height: 1.35),
                    ),
                    const SizedBox(height: 12),
                    PebbleButton(label: 'Choose a PC', icon: Icons.devices_rounded, onTap: onChoosePc),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Slab(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: settings.crashReports,
                      onChanged: (value) => settings.setCrashReports(value),
                      activeThumbColor: Palette.accentInk,
                      activeTrackColor: Palette.accent,
                      title: const Text('Send crash reports', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Text(
                        'Errors, crashes, how long startup and opening videos take, and how fast the connection to the PC is '
                        "go to BlackPearl's developer through Sentry. File paths, titles, addresses and names are removed first.",
                        style: TextStyle(color: Palette.muted, fontSize: 13, height: 1.35),
                      ),
                    ),
                    const SizedBox(height: 6),
                    // It rides on crash reports: with those off it shows off and can't be turned on.
                    SwitchListTile(
                      key: const ValueKey('app-log'),
                      contentPadding: EdgeInsets.zero,
                      value: settings.crashReports && settings.appLog,
                      onChanged: settings.crashReports ? (value) => settings.setAppLog(value) : null,
                      activeThumbColor: Palette.accentInk,
                      activeTrackColor: Palette.accent,
                      title: const Text("Send the app's log", style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Text(
                        'Crash reports also say what the app did just before, such as connecting to the PC, opening a '
                        "video or updating, and a connection or update that keeps failing is reported. Only the app's own "
                        'notes, never titles, names or addresses.',
                        style: TextStyle(color: Palette.muted, fontSize: 13, height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),
              if (updater != null) ...[const SizedBox(height: 14), AppUpdates(updater: updater!)],
            ],
          ),
        ),
      ),
    );
  }
}

/// The app's version, and a way to check for a newer one now instead of waiting for the next automatic check.
class AppUpdates extends StatefulWidget {
  const AppUpdates({super.key, required this.updater});
  final AppUpdater updater;

  @override
  State<AppUpdates> createState() => _AppUpdatesState();
}

class _AppUpdatesState extends State<AppUpdates> {
  /// What the last check from here found, and the release on offer then. A later automatic check that finds another
  /// release makes the answer out of date, so it goes.
  String? _result;
  String? _resultRelease;

  Future<void> _check() async {
    final result = await widget.updater.check(manual: true);
    // A newer version also shows in the banner at the top of the screen.
    if (mounted && result != null) {
      setState(() {
        _result = result;
        _resultRelease = widget.updater.release?.version;
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.updater,
    builder: (context, _) {
      final updater = widget.updater;
      final result = updater.release?.version == _resultRelease ? _result : null;
      return Slab(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('BlackPearl Mobile ${updater.currentVersion}', style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text(
              'The app looks for a newer version when you open it, and offers it at the top of the screen.',
              style: TextStyle(color: Palette.muted, fontSize: 13, height: 1.35),
            ),
            const SizedBox(height: 12),
            PebbleButton(
              label: 'Check for updates',
              icon: Icons.system_update_rounded,
              onTap: updater.checking ? null : () => unawaited(_check()),
            ),
            // Below the button, so nothing above it moves under the finger when the answer comes.
            if (updater.checking || result != null) ...[
              const SizedBox(height: 10),
              Text(updater.checking ? 'Checking…' : result!, style: const TextStyle(color: Palette.muted, fontSize: 13, height: 1.35)),
            ],
          ],
        ),
      );
    },
  );
}
