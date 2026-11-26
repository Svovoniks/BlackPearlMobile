import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../app_model.dart';
import '../connection/remote_connection.dart';
import '../connection/remote_link.dart';
import '../playback/phone_playback.dart';
import '../protocol/library.dart';
import '../update/app_update.dart';
import 'library_screen.dart';
import 'mini_remote_bar.dart';
import 'player_screen.dart';
import 'remote_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';

/// The app once a PC is chosen: Remote, Library, Search and Settings tabs.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.model,
    required this.connection,
    required this.onChoosePc,
    required this.onPairAgain,
    this.updater,
    this.initialTab = HomeShell.remoteTab,
    this.onTabChanged,
  });
  final AppModel model;
  final RemoteConnection connection;
  final VoidCallback onChoosePc;
  final VoidCallback onPairAgain;

  /// Checks for and installs app updates, for Settings; null where the app doesn't update itself.
  final AppUpdater? updater;

  /// The tab shown first: the one that showed before the pairing screen took the place of the tabs, when it was cancelled.
  final int initialTab;

  /// Every tab chosen, so the app can come back to it.
  final ValueChanged<int>? onTabChanged;

  static const remoteTab = 0, libraryTab = 1, searchTab = 2, settingsTab = 3;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late int _tab = widget.initialTab;
  bool _playerOpen = false;

  // The tabs shown before this one, the last most recent, each once: the system's Back goes back through them. The
  // Remote is where they start, so reaching it forgets them, and its Back closes the app.
  final List<int> _visited = [];

  void _showTab(int tab, {bool back = false}) {
    if (!mounted || tab == _tab) return;
    if (tab == HomeShell.remoteTab) {
      _visited.clear();
    } else if (!back) {
      _visited
        ..remove(tab)
        ..add(_tab);
    }
    setState(() => _tab = tab);
    widget.onTabChanged?.call(tab);
  }

  // Back from a tab other than the Remote: to the tab shown before it, or to the Remote when there is none.
  void _back() => _showTab(_visited.isEmpty ? HomeShell.remoteTab : _visited.removeLast(), back: true);

  /// Bumped when the phone's player closes or the PC starts a title, so the Library shows the new resume points.
  final ValueNotifier<int> _playbackChanged = ValueNotifier(0);

  /// Bumped when the Library tab is tapped while it shows: its list goes back to the top.
  final ValueNotifier<int> _libraryTop = ValueNotifier(0);

  /// Bumped when the Search tab is tapped: its field takes the keyboard.
  final ValueNotifier<int> _searchChosen = ValueNotifier(0);

  @override
  void dispose() {
    _playbackChanged.dispose();
    _libraryTop.dispose();
    _searchChosen.dispose();
    super.dispose();
  }

  // The Remote, over whatever page is open above the tabs.
  void _showRemote() {
    Navigator.of(context).popUntil((route) => route.isFirst);
    _showTab(HomeShell.remoteTab);
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
      builder: (_) => PlayerScreen(playback: playback, pcName: link.pcName, settings: widget.model.settings, onHandedToPc: () => _showTab(HomeShell.remoteTab)),
    ));
    _playerOpen = false;
    // Left while it was still opening: a request still waiting for the link is not sent any more (Watch here would
    // stop the PC's video for a player that is gone).
    playback.cancelOpening(viewing);
    await opened;
    // The player is off screen now, so its picture can go.
    await playback.stop(viewing: viewing);
    // The PC saves the last report a moment after it arrives.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (mounted) _playbackChanged.value++;
  }

  late final LibraryActions _actions = LibraryActions(
    openRemote: _showRemote,
    // Where a video was started last is where the play buttons on lists start the next one.
    prefersPc: () => widget.model.settings.playOnPc,
    watchHere: (entry, {bool fromStart = false, QueueRef? queue}) {
      unawaited(widget.model.settings.setPlayOnPc(false));
      return _openPlayer((playback) => playback.watch(entry.id, startAt: fromStart ? 0 : null, queue: queue));
    },
    playOnPc: (entry, {bool fromStart = false, QueueRef? queue}) async {
      unawaited(widget.model.settings.setPlayOnPc(true));
      try {
        await link.ask('play', {
          'id': entry.id,
          'positionMs': fromStart || entry.watched ? 0 : entry.positionMs,
          if (queue != null) ...{'queue': queue.id, 'queueIndex': ?queue.index},
        }, timeout: const Duration(seconds: 30));
      } on RemoteRequestException catch (e) {
        return e.message;
      }
      if (mounted) {
        // The Remote shows what the PC now plays: over a show's or season's page too, which close for it.
        Navigator.of(context).popUntil((route) => route.isFirst);
        _showTab(HomeShell.remoteTab);
      }
      _playbackChanged.value++;
      return null;
    },
    markWatched: (entry, watched, {String? level, int? season}) async {
      // Continue watching names the episode to resume, whatever its card's level: the mark is that file's.
      final file = entry.playable && level == null;
      try {
        await link.ask('mark-watched', {
          'id': entry.id,
          'level': level ?? (file ? (entry.level == 'movie' ? 'movie' : 'episode') : entry.level),
          if ((level ?? entry.level) == 'season') 'season': season ?? entry.season,
          'watched': watched,
        });
      } on RemoteRequestException catch (e) {
        return e.message;
      }
      // Every list shown loads again, so Home, the show's page and the cards show the new marks.
      _playbackChanged.value++;
      return null;
    },
  );

  @override
  Widget build(BuildContext context) {
    final tabs = [
      RemoteScreen(
        link: link,
        sound: widget.model.sound,
        onChoosePc: widget.onChoosePc,
        onPairAgain: widget.onPairAgain,
        onWatchHere: playback == null ? null : (id) => _openPlayer((playback) => playback.watch(id, takeOver: true)),
        onBrowseLibrary: () => _showTab(HomeShell.libraryTab),
        // From the screen that says nothing is playing: the title starts on the PC, and the Remote stays in front.
        onPlayOnPc: (entry) => _actions.playOnPc(entry),
        changed: _playbackChanged,
        active: _tab == HomeShell.remoteTab,
      ),
      LibraryScreen(
        link: link,
        actions: _actions,
        changed: _playbackChanged,
        toTop: _libraryTop,
      ),
      SearchScreen(link: link, actions: _actions, changed: _playbackChanged, chosen: _searchChosen, active: _tab == HomeShell.searchTab),
      SettingsScreen(model: widget.model, link: link, onChoosePc: widget.onChoosePc, updater: widget.updater),
    ];
    // The system's Back goes back to the tab shown before rather than closing the app; only the Remote's closes it.
    return PopScope(
      canPop: _tab == HomeShell.remoteTab,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        body: IndexedStack(index: _tab, children: tabs),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Away from the Remote, what the PC plays keeps its play buttons within reach.
            if (_tab != HomeShell.remoteTab) MiniRemoteBar(link: link, onOpen: () => _showTab(HomeShell.remoteTab), safeBottom: false),
            AppTabBar(
              index: _tab,
              onSelect: (index) {
                if (index == _tab && index == HomeShell.libraryTab) _libraryTop.value++;
                if (index == HomeShell.searchTab) _searchChosen.value++;
                _showTab(index);
              },
            ),
          ],
        ),
      ),
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
    (Icons.search_rounded, Icons.search_rounded, 'Search'),
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
                          // Four tabs share a narrow phone: a label too long at large text shrinks rather than breaks.
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              _tabs[i].$3,
                              maxLines: 1,
                              style: TextStyle(color: i == index ? Palette.accent : Palette.muted, fontSize: 11.5, fontWeight: FontWeight.w600),
                            ),
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
