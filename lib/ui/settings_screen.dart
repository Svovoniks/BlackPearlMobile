import 'package:material_ui/material_ui.dart';

import '../app_model.dart';
import '../background/background_link.dart';
import '../connection/remote_link.dart';
import '../storage/app_settings.dart';
import 'home_shell.dart';
import 'pebbles.dart';
import 'theme.dart';

/// The Settings tab: the background connection, the quality away from home, and the paired PCs.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.model, required this.link, required this.onChoosePc, this.version});
  final AppModel model;
  final RemoteLink link;
  final VoidCallback onChoosePc;
  final Widget? version;

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
                            ? 'The phone keeps its connection to ${link.pcName} after you close the app, so the notification '
                                  'shows what plays there with a Play/Pause button, and the app opens already connected. '
                                  'Android shows the notification while this is on; its Turn off button switches it off too.'
                            : 'Only BlackPearl on Android stays connected in the background.',
                        style: const TextStyle(color: Palette.muted, fontSize: 13, height: 1.35),
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
              if (version != null) ...[const SizedBox(height: 18), Center(child: version!)],
            ],
          ),
        ),
      ),
    );
  }
}
