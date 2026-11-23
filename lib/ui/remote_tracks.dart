import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../connection/remote_link.dart';
import '../playback/track_languages.dart';
import '../protocol/remote_state.dart';
import 'player_options.dart';
import 'theme.dart';

/// A page of the Remote tab's tracks sheet.
enum RemoteTracksTab { audio, subtitles }

/// The PC player's Audio and Subtitles menus, for the Remote tab: the same choices with the same tick, and a tap
/// chooses as a click in the PC's menu does (PHONE-REMOTE.md, "Tracks").
Future<void> showRemoteTracks(BuildContext context, {required RemoteLink link, RemoteTracksTab tab = RemoteTracksTab.audio}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.62),
      builder: (context) => RemoteTracksPanel(link: link, initialTab: tab),
    );

class RemoteTracksPanel extends StatefulWidget {
  const RemoteTracksPanel({super.key, required this.link, this.initialTab = RemoteTracksTab.audio});
  final RemoteLink link;
  final RemoteTracksTab initialTab;

  @override
  State<RemoteTracksPanel> createState() => _RemoteTracksPanelState();
}

class _RemoteTracksPanelState extends State<RemoteTracksPanel> {
  late RemoteTracksTab _tab = widget.initialTab;

  // The choice just sent, ticked until the PC's state shows it, or for a few seconds if it never does.
  ({RemoteTracksTab tab, int id, DateTime at})? _pending;
  Timer? _pendingTimer;

  static const _pendingFor = Duration(seconds: 3);

  RemoteLink get link => widget.link;

  @override
  void initState() {
    super.initState();
    _videoShown = _video(link.state);
    link.addListener(_changed);
    link.notice.addListener(_noticed);
  }

  // What the PC said it couldn't do, such as change a track: shown here, as the Remote's own message would sit behind
  // the sheet.
  String? _problem;
  Timer? _problemTimer;

  void _noticed() {
    final text = link.notice.value;
    if (text == null || !mounted) return;
    setState(() => _problem = text);
    _problemTimer?.cancel();
    _problemTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _problem = null);
    });
  }

  @override
  void didUpdateWidget(RemoteTracksPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.link != link) {
      oldWidget.link.removeListener(_changed);
      oldWidget.link.notice.removeListener(_noticed);
      link.addListener(_changed);
      link.notice.addListener(_noticed);
    }
  }

  @override
  void dispose() {
    link.removeListener(_changed);
    link.notice.removeListener(_noticed);
    _problemTimer?.cancel();
    _pendingTimer?.cancel();
    super.dispose();
  }

  void _changed() {
    final pending = _pending;
    final state = link.state;
    // Ids last only for one video: a choice still waiting when the PC moves on means nothing in the next one.
    final video = _video(state);
    if (video != _videoShown) {
      _videoShown = video;
      _pending = null;
    }
    if (pending != null && state != null && _selected(state, pending.tab) == pending.id) _pending = null;
    if (mounted) setState(() {});
  }

  String? _videoShown;
  static String? _video(RemoteState? state) =>
      state == null || !state.media ? null : '${state.mediaId}|${state.title}|${state.detail}|${state.durationMs}';

  static int? _selected(RemoteState state, RemoteTracksTab tab) => tab == RemoteTracksTab.audio ? state.audioTrack : state.subtitleTrack;

  void _choose(RemoteTracksTab tab, RemoteTrack track) {
    final state = link.state;
    if (state == null || _selected(state, tab) == track.id && _pending == null) return;
    // Marked before sending: a PC that answers at once clears it in the same call.
    setState(() => _pending = (tab: tab, id: track.id, at: DateTime.now()));
    _pendingTimer?.cancel();
    _pendingTimer = Timer(_pendingFor, () {
      if (mounted) setState(() => _pending = null);
    });
    link.command(tab == RemoteTracksTab.audio ? 'audio-track' : 'subtitle-track', track.id);
  }

  @override
  Widget build(BuildContext context) {
    final state = link.state;
    final tracks = state == null || !state.media
        ? const <RemoteTrack>[]
        : (_tab == RemoteTracksTab.audio ? state.audioTracks : state.subtitleTracks) ?? const <RemoteTrack>[];
    final canChange = link.status.isConnected && state != null && state.media && state.canChangeTracks;
    final pending = _pending?.tab == _tab ? _pending : null;
    final ticked = pending?.id ?? (state == null ? null : _selected(state, _tab));
    final labels = _labels(tracks);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 6, 8),
          child: Row(
            children: [
              for (final each in RemoteTracksTab.values)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: OptionTab(
                    label: each == RemoteTracksTab.audio ? 'Audio' : 'Subtitles',
                    selected: each == _tab,
                    onTap: () => setState(() => _tab = each),
                  ),
                ),
              const Spacer(),
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
            child: ListView(
              key: ValueKey(_tab),
              shrinkWrap: true,
              // Clear of the gesture bar, which the sheet draws over.
              padding: EdgeInsets.fromLTRB(10, 0, 10, 16 + MediaQuery.paddingOf(context).bottom),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Text(
                    _tab == RemoteTracksTab.audio ? 'What ${link.pcName} plays' : 'What ${link.pcName} shows',
                    style: const TextStyle(fontSize: 12.5, color: Palette.muted),
                  ),
                ),
                if (_problem != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Text(_problem!, style: const TextStyle(color: Palette.danger, fontSize: 13.5, height: 1.35)),
                  ),
                if (!canChange && link.status.isConnected && state != null && state.media)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _Locked(room: state.room),
                  ),
                for (var i = 0; i < tracks.length; i++)
                  OptionRow(
                    key: ValueKey(('track', _tab, tracks[i].id)),
                    label: labels[i],
                    selected: tracks[i].id == ticked,
                    busy: pending?.id == tracks[i].id,
                    enabled: canChange,
                    onTap: () => _choose(_tab, tracks[i]),
                  ),
                if (state == null || !state.media)
                  const OptionNote('Nothing is playing on the PC.')
                // Once the audio is listed, an empty Subtitles menu is a video without subtitles, as on the PC.
                else if (tracks.isEmpty && _tab == RemoteTracksTab.subtitles && (state.audioTracks?.isNotEmpty ?? false))
                  const OptionNote('This video has no subtitles. Subtitles from a file can be loaded on the PC.')
                else if (tracks.isEmpty)
                  OptionNote(
                    _tab == RemoteTracksTab.audio
                        ? 'The audio tracks show once the video has opened on the PC.'
                        : 'The subtitles show once the video has opened on the PC.',
                  )
                else if (_tab == RemoteTracksTab.subtitles && tracks.every((t) => t.id == RemoteTrack.off))
                  const OptionNote('This video has no subtitles. Subtitles from a file can be loaded on the PC.')
                else if (_tab == RemoteTracksTab.audio && canChange)
                  const OptionNote('Subtitles you haven\'t picked follow the PC\'s rule for the audio\'s language.'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // The PC's menu leads with the language and mutes the rest; Off reads as itself.
  static List<TrackLabel> _labels(List<RemoteTrack> tracks) => [
    for (final track in tracks) track.id == RemoteTrack.off ? const TrackLabel('Off', null) : TrackLabel(track.name, track.detail),
  ];
}

class _Locked extends StatelessWidget {
  const _Locked({required this.room});
  final RemoteRoom? room;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
    decoration: BoxDecoration(color: Palette.accentSoft, borderRadius: BorderRadius.circular(14)),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 1),
          child: Icon(Icons.lock_outline_rounded, size: 18, color: Palette.accent),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            room != null
                ? "In ${room!.name}, the audio and subtitles can't be changed from this PC right now. Usually only whoever plays the video picks them."
                : "The PC can't change tracks right now. Try again in a moment.",
            style: const TextStyle(fontSize: 13, height: 1.35, color: Palette.ink),
          ),
        ),
      ],
    ),
  );
}
