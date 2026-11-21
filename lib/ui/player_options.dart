import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import '../playback/phone_playback.dart';
import '../playback/track_languages.dart';
import '../protocol/library.dart';
import 'theme.dart';

/// A page of the player's options.
enum PlayerOptionsTab { audio, subtitles, quality }

/// Opens the player's options on [tab]: beside the video in landscape, so the picture stays in view, and as a short
/// sheet in portrait.
Future<void> showPlayerOptions(BuildContext context, PhonePlayback playback, {PlayerOptionsTab tab = PlayerOptionsTab.audio}) {
  final size = MediaQuery.sizeOf(context);
  if (size.width > size.height) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: const Color(0x55000000),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, _, _) => Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: (size.width * 0.42).clamp(320.0, 420.0),
          height: double.infinity,
          child: Material(
            color: Palette.surface,
            borderRadius: const BorderRadius.horizontal(left: Radius.circular(26)),
            clipBehavior: Clip.antiAlias,
            child: SafeArea(
              left: false,
              child: PlayerOptionsPanel(playback: playback, initialTab: tab),
            ),
          ),
        ),
      ),
      transitionBuilder: (context, animation, _, child) => SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic)),
        child: child,
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: BoxConstraints(maxHeight: size.height * 0.62),
    builder: (context) => PlayerOptionsPanel(playback: playback, initialTab: tab),
  );
}

/// Audio, subtitles and quality, one page each, with what plays now ticked.
class PlayerOptionsPanel extends StatefulWidget {
  const PlayerOptionsPanel({super.key, required this.playback, this.initialTab = PlayerOptionsTab.audio});
  final PhonePlayback playback;
  final PlayerOptionsTab initialTab;

  @override
  State<PlayerOptionsPanel> createState() => _PlayerOptionsPanelState();
}

class _PlayerOptionsPanelState extends State<PlayerOptionsPanel> {
  late PlayerOptionsTab _tab = widget.initialTab;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  String? _audio, _subtitle;
  Player? _player;

  PhonePlayback get playback => widget.playback;

  @override
  void initState() {
    super.initState();
    playback.addListener(_changed);
    playback.pending.addListener(_changed);
    _changed();
  }

  @override
  void dispose() {
    playback.removeListener(_changed);
    playback.pending.removeListener(_changed);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  void _changed() {
    final player = playback.player;
    if (!identical(player, _player)) {
      _player = player;
      for (final subscription in _subscriptions) {
        unawaited(subscription.cancel());
      }
      _subscriptions.clear();
      if (player != null) {
        // Tracks arrive once the video has opened, which can be after the panel.
        void refresh(Object? _) => unawaited(_readSelection());
        _subscriptions
          ..add(player.stream.tracks.listen(refresh))
          ..add(player.stream.track.listen(refresh));
      }
    }
    unawaited(_readSelection());
    if (mounted) setState(() {});
  }

  Future<void> _readSelection() async {
    final selected = await playback.selectedTracks();
    if (!mounted) return;
    setState(() {
      _audio = selected.audio;
      _subtitle = selected.subtitle;
    });
  }

  @override
  Widget build(BuildContext context) {
    final stream = playback.stream;
    final tracks = playback.player?.state.tracks ?? const Tracks();
    final tabs = [
      PlayerOptionsTab.audio,
      PlayerOptionsTab.subtitles,
      if (stream != null && stream.qualities.length > 1) PlayerOptionsTab.quality,
    ];
    final tab = tabs.contains(_tab) ? _tab : tabs.first;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 6, 8),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final each in tabs)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: _TabPill(
                            label: switch (each) {
                              PlayerOptionsTab.audio => 'Audio',
                              PlayerOptionsTab.subtitles => 'Subtitles',
                              PlayerOptionsTab.quality => 'Quality',
                            },
                            selected: each == tab,
                            onTap: () => setState(() => _tab = each),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close_rounded, color: Palette.muted),
              ),
            ],
          ),
        ),
        Flexible(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            child: KeyedSubtree(
              key: ValueKey(tab),
              child: switch (tab) {
                PlayerOptionsTab.audio => _audioPage(tracks),
                PlayerOptionsTab.subtitles => _subtitlePage(tracks, stream),
                PlayerOptionsTab.quality => _qualityPage(stream!),
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _list(List<Widget> children) => ListView(
    shrinkWrap: true,
    padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
    children: children,
  );

  Widget _audioPage(Tracks tracks) {
    final audio = PhonePlayback.audioChoices(tracks);
    if (audio.isEmpty) return _list([const _Note('The audio tracks show once the video has opened.')]);
    final labels = audioLabels(audio);
    return _list([
      for (var i = 0; i < audio.length; i++)
        _OptionRow(
          label: labels[i],
          selected: audio[i].id == _audio || audio.length == 1,
          onTap: () => unawaited(playback.chooseAudio(audio[i])),
        ),
    ]);
  }

  Widget _subtitlePage(Tracks tracks, StreamInfo? stream) {
    final subtitles = PhonePlayback.subtitleChoices(tracks);
    final labels = subtitleLabels(subtitles);
    return _list([
      _OptionRow(
        label: const TrackLabel('Off', null),
        selected: _subtitle == null,
        onTap: () => unawaited(playback.chooseSubtitle(null)),
      ),
      for (var i = 0; i < subtitles.length; i++)
        _OptionRow(
          label: labels[i],
          selected: subtitles[i].id == _subtitle,
          onTap: () => unawaited(playback.chooseSubtitle(subtitles[i])),
        ),
      if (subtitles.isEmpty && stream != null)
        stream.hls
            ? _Note(
                'A converted stream carries no subtitles. The original file has them.',
                action: stream.qualities.contains('original') ? 'Play the original file' : null,
                onAction: () => unawaited(playback.changeQuality('original')),
              )
            : const _Note('This video has no subtitles.'),
    ]);
  }

  Widget _qualityPage(StreamInfo stream) {
    final pending = playback.pending.value?.quality;
    return _list([
      for (final quality in stream.qualities)
        _OptionRow(
          label: TrackLabel(
            qualityLabel(quality),
            pending == quality
                ? 'Switching…'
                : quality == 'original'
                ? 'The file as it is, the best picture'
                : 'Converted by the PC as you watch',
          ),
          selected: pending == null ? stream.quality == quality : pending == quality,
          busy: pending == quality,
          onTap: () => unawaited(playback.changeQuality(quality)),
        ),
      const _Note('A lower quality plays smoother on a slow connection. Away from home the player starts at the quality in Settings.'),
    ]);
  }
}

class _TabPill extends StatelessWidget {
  const _TabPill({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: Material(
      color: selected ? Palette.accent : Palette.elevated,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Text(
            label,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: selected ? Palette.accentInk : Palette.ink),
          ),
        ),
      ),
    ),
  );
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.label, required this.selected, required this.onTap, this.busy = false});
  final TrackLabel label;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? Palette.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: busy
                        ? const Padding(padding: EdgeInsets.all(2), child: CircularProgressIndicator(strokeWidth: 2.2, color: Palette.accent))
                        : selected
                        ? const Icon(Icons.check_circle_rounded, color: Palette.accent, size: 22)
                        : const Icon(Icons.circle_outlined, color: Color(0x669BA89F), size: 22),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 15, fontWeight: selected ? FontWeight.w600 : FontWeight.w500, color: Palette.ink),
                        ),
                        if (label.detail != null)
                          Text(
                            label.detail!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12.5, color: Palette.muted),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text, {this.action, this.onAction});
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: const TextStyle(color: Palette.muted, fontSize: 13, height: 1.35)),
        if (action != null)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Palette.accent, padding: EdgeInsets.zero),
            onPressed: onAction,
            child: Text(action!),
          ),
      ],
    ),
  );
}
