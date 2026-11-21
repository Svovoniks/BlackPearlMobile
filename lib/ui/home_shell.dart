import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../app_model.dart';
import '../connection/remote_connection.dart';
import '../connection/remote_link.dart';
import '../playback/phone_playback.dart';
import '../protocol/library.dart';
import 'library_screen.dart';
import 'player_screen.dart';
import 'remote_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';

/// The app once a PC is chosen: Remote, Library and Settings tabs.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.model, required this.connection, required this.onChoosePc, required this.onPairAgain, this.version});
  final AppModel model;
  final RemoteConnection connection;
  final VoidCallback onChoosePc;
  final VoidCallback onPairAgain;

  /// The app's version line for Settings.
  final Widget? version;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  bool _playerOpen = false;

  /// Bumped when the phone's player closes or the PC starts a title, so the Library shows the new resume points.
  final ValueNotifier<int> _playbackChanged = ValueNotifier(0);

  @override
  void dispose() {
    _playbackChanged.dispose();
    super.dispose();
  }

  RemoteLink get link => widget.connection;
  PhonePlayback? get playback => widget.model.playback;

  void _say(String text) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 6)));

  Future<void> _openPlayer(Future<void> Function(PhonePlayback playback) start) async {
    final playback = this.playback;
    if (playback == null) {
      _say("This phone can't play videos.");
      return;
    }
    if (_playerOpen) return;
    _playerOpen = true;
    final viewing = playback.startViewing();
    final opened = start(playback);
    await Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => PlayerScreen(playback: playback, pcName: link.pcName, settings: widget.model.settings, onHandedToPc: () => setState(() => _tab = 0)),
    ));
    _playerOpen = false;
    await opened;
    // The player is off screen now, so its picture can go.
    await playback.stop(viewing: viewing);
    // The PC saves the last report a moment after it arrives.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (mounted) _playbackChanged.value++;
  }

  late final LibraryActions _actions = LibraryActions(
    watchHere: (entry, {bool fromStart = false, QueueRef? queue}) =>
        _openPlayer((playback) => playback.watch(entry.id, startAt: fromStart ? 0 : null, queue: queue)),
    playOnPc: (entry, {bool fromStart = false, QueueRef? queue}) async {
      try {
        await link.ask('play', {
          'id': entry.id,
          'positionMs': fromStart || entry.watched ? 0 : entry.positionMs,
          if (queue != null) ...{'queue': queue.id, 'queueIndex': ?queue.index},
        }, timeout: const Duration(seconds: 30));
      } on RemoteRequestException catch (e) {
        return e.message;
      }
      if (mounted) setState(() => _tab = 0);
      _playbackChanged.value++;
      return null;
    },
  );

  @override
  Widget build(BuildContext context) {
    final tabs = [
      RemoteScreen(
        link: link,
        onChoosePc: widget.onChoosePc,
        onPairAgain: widget.onPairAgain,
        onWatchHere: playback == null ? null : (id) => _openPlayer((playback) => playback.watch(id, takeOver: true)),
      ),
      LibraryScreen(link: link, actions: _actions, changed: _playbackChanged),
      SettingsScreen(model: widget.model, link: link, onChoosePc: widget.onChoosePc, version: widget.version),
    ];
    return Scaffold(
      body: IndexedStack(index: _tab, children: tabs),
      bottomNavigationBar: AppTabBar(index: _tab, onSelect: (index) => setState(() => _tab = index)),
    );
  }
}

/// The bottom tab bar.
class AppTabBar extends StatelessWidget {
  const AppTabBar({super.key, required this.index, required this.onSelect});
  final int index;
  final void Function(int index) onSelect;

  static const _tabs = [
    (Icons.settings_remote_outlined, Icons.settings_remote, 'Remote'),
    (Icons.video_library_outlined, Icons.video_library, 'Library'),
    (Icons.tune_outlined, Icons.tune, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Container(
      padding: EdgeInsets.only(top: 6, bottom: math.max(8, bottom)),
      decoration: const BoxDecoration(
        color: Palette.canvas,
        border: Border(top: BorderSide(color: Palette.elevated)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < _tabs.length; i++)
            Expanded(
              child: Semantics(
                selected: i == index,
                button: true,
                label: _tabs[i].$3,
                child: InkResponse(
                  onTap: () => onSelect(i),
                  radius: 36,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: ExcludeSemantics(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(i == index ? _tabs[i].$2 : _tabs[i].$1, color: i == index ? Palette.accent : Palette.muted, size: 22),
                          const SizedBox(height: 3),
                          Text(
                            _tabs[i].$3,
                            style: TextStyle(color: i == index ? Palette.accent : Palette.muted, fontSize: 11.5, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The quality setting's choices, as Settings and the player name them.
String awayQualityLabel(String id) => switch (id) {
  'auto' => 'Automatic (720p)',
  _ => qualityLabel(id),
};
