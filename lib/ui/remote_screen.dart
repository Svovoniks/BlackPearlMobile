import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../connection/remote_link.dart';
import '../connection/transport.dart';
import '../playback/phone_sound.dart';
import '../protocol/library.dart';
import '../protocol/remote_state.dart';
import '../storage/app_settings.dart';
import 'library_screen.dart' show ContinueCard, LibraryListing;
import 'pebbles.dart';
import 'queue_widgets.dart';
import 'remote_tracks.dart';
import 'status_copy.dart';
import 'theme.dart';

export 'status_copy.dart';

/// The Remote tab: what's playing on the PC and everything the player's bars do.
class RemoteScreen extends StatefulWidget {
  const RemoteScreen({
    super.key,
    required this.link,
    required this.onChoosePc,
    required this.onPairAgain,
    this.onWatchHere,
    this.sound,
    this.onBrowseLibrary,
    this.onPlayOnPc,
    this.changed,
    this.active = true,
  });

  final RemoteLink link;

  /// Shows the Library, from the screen that says nothing is playing; null leaves the button out.
  final VoidCallback? onBrowseLibrary;

  /// Starts a title on the PC from where it stopped, for the Continue watching row shown while nothing plays; returns
  /// why it couldn't, or null. Null leaves the row out.
  final Future<String?> Function(LibraryEntry entry)? onPlayOnPc;

  /// Fires when playback elsewhere changed resume points: the Continue watching row loads again.
  final Listenable? changed;

  /// Whether this tab is the one showing; behind another, its clock doesn't tick.
  final bool active;

  /// Sound on the phone, for a PC that can send its sound; null leaves the option out.
  final PhoneSound? sound;

  /// Moves the PC's video to the phone: the PC stops and the phone continues it.
  final void Function(String mediaId)? onWatchHere;

  /// Opens the PC chooser (switch, pair another, forget).
  final VoidCallback onChoosePc;

  /// For failures only pairing again can fix.
  final VoidCallback onPairAgain;

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  Timer? _ticker;
  Timer? _volumeTimer, _volumeSettleTimer;
  int? _volumeOverride;
  DateTime _volumeChangedAt = DateTime.fromMillisecondsSinceEpoch(0);
  int? _sentVolume;
  int? _seekTarget;
  DateTime? _seekAt;
  double? _dragFraction;
  // The video a timeline drag began on.
  String? _dragVideo;
  String? _feedback;
  Timer? _feedbackTimer;

  RemoteLink get link => widget.link;
  PhoneSound? get _sound => widget.sound;

  /// Whether the volume row and the touch pad's slide are the phone's, while it plays the PC's sound.
  bool get _phoneVolume => _sound?.on ?? false;

  @override
  void initState() {
    super.initState();
    link.addListener(_changed);
    link.notice.addListener(_showNotice);
    _sound?.addListener(_soundChanged);
    _sound?.notice.addListener(_showSoundNotice);
    _syncTicker();
  }

  void _soundChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(RemoteScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.link != link) {
      oldWidget.link.removeListener(_changed);
      oldWidget.link.notice.removeListener(_showNotice);
      link.addListener(_changed);
      link.notice.addListener(_showNotice);
      _volumeOverride = null;
      _seekTarget = null;
      // Another PC: what was stopped on the last one isn't its to resume.
      _stopped = null;
    }
    if (oldWidget.active != widget.active) _syncTicker();
    if (oldWidget.sound != widget.sound) {
      oldWidget.sound?.removeListener(_soundChanged);
      oldWidget.sound?.notice.removeListener(_showSoundNotice);
      widget.sound?.addListener(_soundChanged);
      widget.sound?.notice.addListener(_showSoundNotice);
    }
  }

  @override
  void dispose() {
    link.removeListener(_changed);
    link.notice.removeListener(_showNotice);
    _sound?.removeListener(_soundChanged);
    _sound?.notice.removeListener(_showSoundNotice);
    _ticker?.cancel();
    _stopTimer?.cancel();
    _tick.dispose();
    _volumeTimer?.cancel();
    _volumeSettleTimer?.cancel();
    _feedbackTimer?.cancel();
    super.dispose();
  }

  void _changed() {
    // Once the Stop has landed (the PC says nothing plays), a PC that plays again leaves nothing stopped to resume. A
    // state it sent just before the Stop reached it still says it plays, and doesn't count.
    if (_stopped != null) {
      if (!(link.state?.media ?? false)) {
        _stopLanded = true;
      } else if (_stopLanded) {
        _stopped = null;
      }
    }
    final at = link.stateReceivedAt;
    // A state that arrived after the seek replaces the guess once it shows the seek, or after a while if it never does:
    // one the PC sent before the seek reached it put the knob back for a moment.
    final seekAt = _seekAt, target = _seekTarget;
    if (seekAt != null && at != null && at.isAfter(seekAt)) {
      final since = clock.now().difference(seekAt);
      final guess = target == null ? null : target + (_state?.playing == true ? since.inMilliseconds : 0);
      if (guess == null || (link.currentPositionMs() - guess).abs() < 2000 || since > const Duration(milliseconds: 1500)) {
        _seekTarget = null;
        _seekAt = null;
      }
    }
    if (_volumeOverride != null && DateTime.now().difference(_volumeChangedAt) > const Duration(milliseconds: 1500)) {
      _volumeOverride = null;
    }
    // A timeline that goes grey under the finger (the link dropped) gets no end to its drag, and neither does one whose
    // video changed: the drag ends here, and the knob follows the PC again.
    if (_dragFraction != null && (!_canPlay || (_state?.durationMs ?? 0) <= 0 || _videoOf(_state) != _dragVideo)) _dragFraction = null;
    _syncTicker();
    setState(() {});
  }

  // Moves the timeline and its clocks while the PC plays, and only those: the rest of the screen is built again when
  // the PC says something new. Behind another tab nothing ticks.
  final ValueNotifier<int> _tick = ValueNotifier(0);

  void _syncTicker() {
    final playing = widget.active && link.state?.playing == true && link.status.isConnected;
    if (playing && _ticker == null) {
      _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) => _tick.value++);
    } else if (!playing) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  // ---- Stop, and taking it back ----

  // The library video this phone's Stop ended, and where: the empty screen offers to play it again from there.
  ({String id, String title, int positionMs, QueueRef? queue})? _stopped;
  bool _stopLanded = false;
  Timer? _stopTimer;
  bool _resuming = false;

  void _stop() {
    final state = _state;
    final id = state?.mediaId;
    if (state != null && id != null && link.canStart && link.features.contains('library')) {
      _stopped = (id: id, title: state.title.isEmpty ? 'the video' : state.title, positionMs: _position, queue: state.queue);
      _stopLanded = false;
      // A Stop the PC didn't act on leaves nothing to take back: the video it ends by itself later isn't this one's.
      _stopTimer?.cancel();
      _stopTimer = Timer(const Duration(seconds: 3), () {
        if (!_stopLanded) _stopped = null;
      });
    }
    link.command('stop');
  }

  Future<void> _resume() async {
    final stopped = _stopped;
    if (stopped == null || _resuming) return;
    setState(() => _resuming = true);
    String? error;
    try {
      await link.ask('play', {
        'id': stopped.id,
        'positionMs': stopped.positionMs,
        if (stopped.queue != null) ...{'queue': stopped.queue!.id, 'queueIndex': ?stopped.queue!.index},
      }, timeout: const Duration(seconds: 30));
    } on RemoteRequestException catch (e) {
      error = e.message;
    }
    if (!mounted) return;
    setState(() => _resuming = false);
    if (error != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error), duration: const Duration(seconds: 4)));
    }
  }

  void _showSoundNotice() {
    final text = _sound?.notice.value;
    if (text == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
  }

  void _showNotice() {
    final text = link.notice.value;
    if (text == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
  }

  void _flash(String text) {
    _feedbackTimer?.cancel();
    setState(() => _feedback = text);
    _feedbackTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _feedback = null);
    });
  }

  // ---- commands ----

  bool get _connected => link.status.isConnected;
  RemoteState? get _state => link.state;
  bool get _canPlay => _connected && (_state?.media ?? false) && (_state?.canControl ?? false);
  bool get _canAdjust => _connected && (_state?.media ?? false);

  static String? _videoOf(RemoteState? state) =>
      state == null || !state.media ? null : '${state.mediaId}|${state.title}|${state.detail}|${state.durationMs}';

  int get _position {
    if (_dragFraction != null) return (_dragFraction! * (_state?.durationMs ?? 0)).round();
    if (_seekTarget != null && _seekAt != null) {
      final elapsed = _state?.playing == true ? clock.now().difference(_seekAt!).inMilliseconds : 0;
      final duration = _state?.durationMs ?? 0;
      final position = _seekTarget! + elapsed;
      return duration > 0 ? math.min(position, duration) : position;
    }
    return link.currentPositionMs();
  }

  int get _volume => _phoneVolume ? _sound!.volume : _volumeOverride ?? _state?.volume ?? 0;
  bool get _muted => _phoneVolume ? _sound!.muted : _state?.muted ?? false;

  void _toggleMute() {
    if (_phoneVolume) {
      unawaited(_sound!.toggleMute());
    } else {
      link.command('mute');
    }
  }

  /// A PC that can send its sound gets the Sound pill.
  bool get _soundOffered => _sound != null && link.features.contains('sound');

  void _seekBy(int ms) {
    if (!_canPlay) return;
    // The guess is made before sending: a state that answers the command must replace it, not add to it.
    final duration = _state?.durationMs ?? 0;
    _seekTarget = (_position + ms).clamp(0, duration > 0 ? duration : 1 << 40);
    _seekAt = clock.now();
    link.command('seek-by', ms);
    _flash(ms > 0 ? '+${ms ~/ 1000} s' : '−${-ms ~/ 1000} s');
  }

  void _seekTo(double fraction) {
    final duration = _state?.durationMs ?? 0;
    if (!_canPlay || duration <= 0) return;
    final target = (fraction.clamp(0.0, 1.0) * duration).round();
    _seekTarget = target;
    _seekAt = clock.now();
    link.command('seek-to', target);
  }

  void _toggle() {
    if (!_canPlay) return;
    final label = _state?.playing == true ? 'Pause' : 'Play';
    link.command('toggle');
    _flash(label);
  }

  /// Sends volume changes at most every 150 ms while dragging, and the final value at the end.
  void _setVolume(int value, {bool done = false}) {
    if (!_canAdjust) return;
    final clamped = value.clamp(0, 100);
    if (_phoneVolume) {
      unawaited(_sound!.setVolume(clamped));
      return;
    }
    setState(() {
      _volumeOverride = clamped;
      _volumeChangedAt = DateTime.now();
    });
    // The PC's own value shows again once the change has settled, also when no further state comes to clear it (a
    // paused PC sends none), so a change made on the PC meanwhile isn't hidden behind this one.
    _volumeSettleTimer?.cancel();
    _volumeSettleTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted && _volumeOverride != null) setState(() => _volumeOverride = null);
    });
    if (done) {
      _volumeTimer?.cancel();
      _volumeTimer = null;
      _sendVolume(always: true);
      return;
    }
    if (_volumeTimer == null) {
      _sendVolume();
      _volumeTimer = Timer(const Duration(milliseconds: 150), () {
        _volumeTimer = null;
        _sendVolume();
      });
    }
  }

  void _sendVolume({bool always = false}) {
    final value = _volumeOverride;
    if (value == null || (!always && value == _sentVolume)) return;
    _sentVolume = value;
    link.command('volume', value);
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    final status = link.status;
    final state = _state;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // The chips are 36 dp in a row a fingertip high, which stands where their 10 dp of room above was.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Row(
                children: [
                  // The PC's name gets the room it needs; the room chip shrinks first.
                  Flexible(
                    flex: 3,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _PcChip(link: link, onTap: widget.onChoosePc),
                    ),
                  ),
                  if (state?.room != null && status.isConnected) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      flex: 2,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _RoomChip(room: state!.room!),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(child: _body(status, state)),
          ],
        ),
      ),
    );
  }

  Widget _body(LinkStatus status, RemoteState? state) {
    if (state == null) {
      if (status.isConnected) return const _Centered(child: CircularProgressIndicator(color: Palette.accent, strokeWidth: 2.5));
      return _ConnectionPanel(link: link, onPairAgain: widget.onPairAgain, onChoosePc: widget.onChoosePc);
    }
    final banner = [if (!status.isConnected) ...[_ConnectionBanner(link: link, onPairAgain: widget.onPairAgain), const SizedBox(height: 12)]];
    return LayoutBuilder(
      builder: (context, constraints) {
        // Sideways, the touch pad takes the left side and the controls the right, starting with the title, timeline and
        // play buttons: under the pad, those were below the fold.
        if (state.media && constraints.maxWidth > constraints.maxHeight && constraints.maxWidth >= 560) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 5, child: Padding(padding: const EdgeInsets.only(bottom: 12), child: _touchPad())),
                const SizedBox(width: 20),
                Expanded(
                  flex: 6,
                  // Sideways the volume scrolls with the rest: pinned, it would push the play buttons out of view.
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [...banner, ..._playing(state, sideways: true), const SizedBox(height: 12), _volumeRow()],
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        return _upright(state, banner);
      },
    );
  }

  Widget _upright(RemoteState state, List<Widget> banner) {
    final children = <Widget>[
      ...banner,
      if (!state.media)
        _Nothing(
          link: link,
          stopped: _stopped,
          resuming: _resuming,
          onResume: _resume,
          onBrowseLibrary: widget.onBrowseLibrary,
          onPlayOnPc: widget.onPlayOnPc,
          changed: widget.changed,
        )
      else ...[
        Expanded(
          child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 116), child: _touchPad()),
        ),
        const SizedBox(height: 16),
        ..._playing(state),
      ],
      // The room under the last row is part of what fills the screen: as the sliver's own padding it came after a
      // full screen, so the page always scrolled by that much.
      const SizedBox(height: 12),
    ];
    // The touch pad takes whatever height the controls leave. On a screen too short for its smallest size, it all
    // scrolls instead of squeezing.
    final scrolled = CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          sliver: SliverFillRemaining(
            hasScrollBody: false,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
        ),
      ],
    );
    if (!state.media) return scrolled;
    // The volume stays in reach under whatever scrolls, just above the tab bar.
    return Column(
      children: [
        Expanded(child: scrolled),
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: _volumeRow()),
      ],
    );
  }

  static const _volumeStyle = TextStyle(color: Palette.muted, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]);

  static double _labelWidth(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width.ceilToDouble() + 1;
    painter.dispose();
    return width;
  }

  Widget _touchPad() => _TouchPad(
    enabled: _canPlay,
    volumeEnabled: _canAdjust,
    feedback: _feedback,
    onTap: _toggle,
    onSwipe: (forward) => _seekBy(forward ? 10000 : -10000),
    volume: () => _volume,
    onVolume: (value, done) {
      _setVolume(value, done: done);
      _flash(_phoneVolume ? 'Phone volume $value%' : 'Volume $value%');
    },
  );

  /// Everything but the touch pad, from the title down.
  /// [sideways]: beside the touch pad, where the title and its detail take a line each, to leave the play buttons in view.
  List<Widget> _playing(RemoteState state, {bool sideways = false}) {
    final duration = state.durationMs;
    const clockStyle = TextStyle(color: Palette.muted, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]);
    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(state.title.isEmpty ? 'Untitled' : state.title, style: display(26), maxLines: sideways ? 1 : 2, overflow: TextOverflow.ellipsis),
                if (state.detail.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    state.detail,
                    style: const TextStyle(color: Palette.muted, fontSize: 14),
                    maxLines: sideways ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (state.mediaId != null && widget.onWatchHere != null && link.features.contains('watch')) ...[
            const SizedBox(width: 12),
            Pebble(
              height: 40,
              enabled: _connected,
              onTap: () => widget.onWatchHere!(state.mediaId!),
              semanticLabel: 'Watch on this phone',
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [Icon(Icons.phone_android_rounded, size: 18), SizedBox(width: 6), Text('Watch here', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600))],
              ),
            ),
          ],
        ],
      ),
      // The timeline takes touches over 44 dp, 14 more than it used to: 7 of them come out of the room above it.
      const SizedBox(height: 9),
      // The timeline and its clocks follow the PC's position between its messages, on their own (see _tick).
      ValueListenableBuilder<int>(
        valueListenable: _tick,
        builder: (context, _, _) {
          final position = _position;
          final fraction = duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Timeline(
                fraction: _dragFraction ?? fraction,
                enabled: _canPlay && duration > 0,
                onDrag: (value) => setState(() {
                  if (_dragFraction == null) _dragVideo = _videoOf(state);
                  _dragFraction = value;
                }),
                onRelease: (value) {
                  _seekTo(value);
                  setState(() => _dragFraction = null);
                },
                onCancel: () => setState(() => _dragFraction = null),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Each shrinks rather than spill past the edge on a narrow phone with very large text.
                  Flexible(
                    child: FittedBox(fit: BoxFit.scaleDown, child: Text(formatClock(position), style: clockStyle)),
                  ),
                  Flexible(
                    child: FittedBox(fit: BoxFit.scaleDown, child: Text(duration > 0 ? '−${formatClock(duration - position)}' : '', style: clockStyle)),
                  ),
                ],
              ),
            ],
          );
        },
      ),
      if (!state.canControl && _connected) ...[const SizedBox(height: 12), _CantControl(room: state.room)],
      const SizedBox(height: 9),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Pebble(
            width: 52,
            height: 52,
            enabled: _canPlay && state.hasPrevious,
            onTap: () => link.command('previous'),
            semanticLabel: 'Previous',
            child: const Icon(Icons.skip_previous_rounded, size: 26),
          ),
          Pebble(
            width: 52,
            height: 52,
            enabled: _canPlay,
            onTap: () => _seekBy(-10000),
            semanticLabel: 'Back 10 seconds',
            child: const Icon(Icons.replay_10_rounded, size: 26),
          ),
          Pebble(
            width: 80,
            height: 80,
            lit: true,
            enabled: _canPlay,
            onTap: _toggle,
            semanticLabel: state.playing ? 'Pause' : 'Play',
            child: Icon(state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 40),
          ),
          Pebble(
            width: 52,
            height: 52,
            enabled: _canPlay,
            onTap: () => _seekBy(10000),
            semanticLabel: 'Forward 10 seconds',
            child: const Icon(Icons.forward_10_rounded, size: 26),
          ),
          Pebble(
            width: 52,
            height: 52,
            enabled: _canPlay && state.hasNext,
            onTap: () => link.command('next'),
            semanticLabel: 'Next',
            child: const Icon(Icons.skip_next_rounded, size: 26),
          ),
        ],
      ),
      const SizedBox(height: 14),
      // What the PC plays in and where its sound goes, on one row: Audio and Subtitles open the PC player's menus (from
      // a PC that sends them), and Sound moves the sound to this phone and back (headphones on the couch).
      if (state.hasTracks || _soundOffered) ...[
        Row(
          children: [
            if (state.hasTracks) ...[
              Expanded(
                child: _TrackPill(
                  label: 'Audio',
                  icon: Icons.graphic_eq_rounded,
                  tracks: state.audioTracks!,
                  selected: state.audioTrack,
                  enabled: _canAdjust,
                  onTap: () => unawaited(showRemoteTracks(context, link: link, tab: RemoteTracksTab.audio)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _TrackPill(
                  label: 'Subtitles',
                  icon: Icons.subtitles_outlined,
                  tracks: state.subtitleTracks!,
                  // A video without subtitles has an empty menu on the PC once its audio is listed: it has none, not "not yet".
                  opened: state.audioTracks!.isNotEmpty,
                  selected: state.subtitleTrack,
                  enabled: _canAdjust,
                  onTap: () => unawaited(showRemoteTracks(context, link: link, tab: RemoteTracksTab.subtitles)),
                ),
              ),
            ],
            if (state.hasTracks && _soundOffered) const SizedBox(width: 8),
            if (_soundOffered)
              Expanded(
                child: _SoundPill(
                  sound: _sound!,
                  elsewhere: state.phoneSound == true,
                  enabled: _connected,
                  onToggle: () {
                    final here = _sound!.on;
                    unawaited(_sound!.toggle());
                    _flash(here ? 'Sound on the PC' : 'Sound on this phone');
                  },
                ),
              ),
          ],
        ),
        // While this phone plays the sound: how it is going, and the delay that lines it up with the picture.
        if (_soundOffered && _sound!.on) ...[const SizedBox(height: 8), _SoundDelay(sound: _sound!)],
        const SizedBox(height: 8),
      ],
      // The order of play, what plays next and the PC's window, as small buttons on one row, as in the phone's own
      // player. Stop comes last, out of the way of the others: a slip onto it ends the video.
      Row(
        children: [
          for (final (index, button) in [
            // Shuffle, from a PC that has it.
            if (state.shuffle != null)
              _ModeButton(
                label: 'Shuffle',
                semanticLabel: 'Shuffle, ${state.shuffle! ? 'On' : 'Off'}',
                icon: Icons.shuffle_rounded,
                active: state.shuffle!,
                enabled: _canPlay,
                onTap: () => link.command('shuffle'),
              ),
            _ModeButton(
              label: switch (state.loop) {
                LoopMode.off => 'Loop',
                LoopMode.all => 'Loop all',
                LoopMode.one => 'Loop one',
              },
              semanticLabel: 'Loop, ${state.loop.label}',
              icon: state.loop == LoopMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
              active: state.loop != LoopMode.off,
              enabled: _canPlay,
              onTap: () => link.command('loop'),
            ),
            // What the PC plays through, to pick another video from: its queue, or the playing show's episodes.
            if (link.features.contains('queues') && (state.queue != null || state.mediaId != null))
              _ModeButton(
                label: 'Up next',
                semanticLabel: state.queue != null ? 'Up next: queue ${state.queue!.name}' : 'Up next: episodes',
                icon: Icons.queue_play_next_rounded,
                enabled: _connected,
                onTap: () => unawaited(showRemoteUpNext(context, link: link, mediaId: state.mediaId, queue: state.queue)),
              ),
            _ModeButton(
              label: 'Fullscreen',
              semanticLabel: 'Fullscreen, ${state.fullscreen ? 'On' : 'Off'}',
              icon: state.fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
              active: state.fullscreen,
              enabled: _canAdjust,
              onTap: () => link.command('fullscreen'),
            ),
            _ModeButton(label: 'Stop', semanticLabel: 'Stop', icon: Icons.stop_rounded, enabled: _canPlay, onTap: _stop),
          ].indexed) ...[if (index > 0) const SizedBox(width: 6), Expanded(child: button)],
        ],
      ),
    ];
  }

  /// Mute and the volume: the PC's, or the phone's while it plays the PC's sound.
  Widget _volumeRow() => Row(
    children: [
      Pebble(
        width: 44,
        height: 44,
        tapArea: Pebble.fingertip,
        enabled: _canAdjust,
        onTap: _toggleMute,
        semanticLabel: _phoneVolume ? (_muted ? 'Unmute the phone' : 'Mute the phone') : (_muted ? 'Unmute' : 'Mute'),
        child: Icon(
          _phoneVolume ? (_muted ? Icons.headset_off_rounded : Icons.headphones_rounded) : (_muted ? Icons.volume_off_rounded : Icons.volume_up_rounded),
          size: 21,
          color: _muted ? Palette.danger : null,
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: _VolumeTrack(
          value: _volume,
          muted: _muted,
          label: _phoneVolume ? 'Phone volume' : 'PC volume',
          enabled: _canAdjust,
          onChanged: (value) => _setVolume(value),
          onChangeEnd: (value) => _setVolume(value, done: true),
        ),
      ),
      const SizedBox(width: 12),
      // As wide as "Muted" at the phone's text size, so neither it nor "100%" wraps, and the track keeps its length.
      SizedBox(
        width: math.max(42.0, _labelWidth(context, 'Muted', _volumeStyle)),
        child: Text(
          _muted ? 'Muted' : '$_volume%',
          textAlign: TextAlign.right,
          maxLines: 1,
          softWrap: false,
          style: _volumeStyle,
        ),
      ),
    ],
  );
}

class _Centered extends StatelessWidget {
  const _Centered({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Center(child: child);
}

/// The PC's name with the connection's dot and an "away" mark.
class _PcChip extends StatelessWidget {
  const _PcChip({required this.link, required this.onTap});
  final RemoteLink link;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = link.status;
    final (Color dot, bool glow) = switch (status.phase) {
      LinkPhase.connected => (Palette.accent, true),
      LinkPhase.failed => (Palette.danger, false),
      LinkPhase.waitingForPc || LinkPhase.idle => (Palette.muted, false),
      _ => (const Color(0xFFE8C66A), false),
    };
    final away = status.isConnected && (status.path == NetworkPath.away || status.path == NetworkPath.relayed);
    return Pebble(
      height: 36,
      tapArea: Pebble.fingertip,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      semanticLabel: 'Choose PC',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: dot,
              boxShadow: glow ? [BoxShadow(color: dot.withValues(alpha: 0.8), blurRadius: 6)] : null,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              link.pcName,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          if (away) ...[
            const SizedBox(width: 7),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(color: Palette.cyan.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(99)),
              child: Text(
                'away',
                style: const TextStyle(color: Palette.cyan, fontSize: 11.5, fontWeight: FontWeight.w600),
              ),
            ),
          ],
          const SizedBox(width: 4),
          const Icon(Icons.expand_more_rounded, size: 18, color: Palette.muted),
        ],
      ),
    );
  }
}

class _RoomChip extends StatelessWidget {
  const _RoomChip({required this.room});
  final RemoteRoom room;
  @override
  Widget build(BuildContext context) => Pebble(
    height: 36,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    semanticLabel: 'In room ${room.name} with ${room.people} people',
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.people_alt_outlined, size: 16),
        const SizedBox(width: 6),
        Flexible(
          child: Text('${room.name} · ${room.people}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
        ),
      ],
    ),
  );
}

/// Big status for when there's nothing to show yet.
class _ConnectionPanel extends StatelessWidget {
  const _ConnectionPanel({required this.link, required this.onPairAgain, required this.onChoosePc});
  final RemoteLink link;
  final VoidCallback onPairAgain;
  final VoidCallback onChoosePc;

  @override
  Widget build(BuildContext context) {
    final status = link.status;
    final copy = describe(status, link.pcName);
    final busy = status.phase == LinkPhase.connecting || status.phase == LinkPhase.linking || status.phase == LinkPhase.pairing;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Well(
              width: 96,
              height: 96,
              child: Center(
                child: busy
                    ? const SizedBox(width: 34, height: 34, child: CircularProgressIndicator(color: Palette.accent, strokeWidth: 2.5))
                    : Icon(copy.icon, size: 38, color: status.phase == LinkPhase.failed ? Palette.danger : Palette.muted),
              ),
            ),
            const SizedBox(height: 22),
            Text(copy.headline, textAlign: TextAlign.center, style: display(24)),
            const SizedBox(height: 8),
            Text(
              copy.detail,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Palette.muted, fontSize: 14.5, height: 1.4),
            ),
            if (status.retryAt != null) ...[const SizedBox(height: 10), _RetryCountdown(at: status.retryAt!)],
            const SizedBox(height: 24),
            if (status.needsPairing) ...[
              SizedBox(
                width: 260,
                child: PebbleButton(label: 'Scan a new code', icon: Icons.qr_code_scanner_rounded, lit: true, onTap: onPairAgain),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: 260,
                child: PebbleButton(label: 'Choose another PC', onTap: onChoosePc),
              ),
            ] else if (status.phase == LinkPhase.failed || status.phase == LinkPhase.waitingForPc) ...[
              SizedBox(
                width: 260,
                child: PebbleButton(
                  label: 'Try again',
                  icon: Icons.refresh_rounded,
                  lit: status.phase == LinkPhase.failed,
                  onTap: link.retryNow,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A slim status above stale content while reconnecting.
class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.link, required this.onPairAgain});
  final RemoteLink link;
  final VoidCallback onPairAgain;

  @override
  Widget build(BuildContext context) {
    final status = link.status;
    final copy = describe(status, link.pcName);
    final busy = status.phase == LinkPhase.connecting || status.phase == LinkPhase.linking || status.phase == LinkPhase.pairing;
    // Its button is 34 dp in a fingertip's height, which stands where 7 dp of the slab's room above and below was.
    return Slab(
      padding: const EdgeInsets.fromLTRB(14, 5, 10, 5),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: busy
                ? const CircularProgressIndicator(color: Palette.accent, strokeWidth: 2)
                : Icon(copy.icon, size: 22, color: status.phase == LinkPhase.failed ? Palette.danger : Palette.muted),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(copy.headline, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                if (status.retryAt != null)
                  _RetryCountdown(at: status.retryAt!, small: true)
                else if (copy.shortDetail != null)
                  Text(copy.shortDetail!, style: const TextStyle(color: Palette.muted, fontSize: 12.5)),
              ],
            ),
          ),
          if (status.needsPairing)
            Pebble(
              height: 34,
              lit: true,
              tapArea: Pebble.fingertip,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              onTap: onPairAgain,
              child: const Text('Pair', style: TextStyle(fontSize: 13)),
            )
          else if (status.phase == LinkPhase.failed || status.phase == LinkPhase.waitingForPc)
            Pebble(
              height: 34,
              tapArea: Pebble.fingertip,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              onTap: link.retryNow,
              child: const Text('Retry', style: TextStyle(fontSize: 13)),
            )
          else
            // Without a button the slab keeps the height it has with one.
            const SizedBox(height: 48),
        ],
      ),
    );
  }
}

class _RetryCountdown extends StatefulWidget {
  const _RetryCountdown({required this.at, this.small = false});
  final DateTime at;
  final bool small;
  @override
  State<_RetryCountdown> createState() => _RetryCountdownState();
}

class _RetryCountdownState extends State<_RetryCountdown> {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = (widget.at.difference(DateTime.now()).inMilliseconds / 1000).ceil();
    return Text(
      seconds > 0 ? 'Trying again in $seconds s' : 'Trying again…',
      style: TextStyle(color: Palette.muted, fontSize: widget.small ? 12.5 : 13.5),
    );
  }
}

class _CantControl extends StatelessWidget {
  const _CantControl({required this.room});
  final RemoteRoom? room;
  @override
  Widget build(BuildContext context) => Slab(
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
    color: Palette.accentSoft,
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
            room == null
                ? 'In this room, only whoever plays the video can control playback.'
                : 'In ${room!.name}, only whoever plays the video can control playback.',
            style: const TextStyle(fontSize: 13, height: 1.35, color: Palette.ink),
          ),
        ),
      ],
    ),
  );
}

/// Nothing plays on the PC. Rather than only say so, the screen offers what comes next: the Library, the video this
/// phone's Stop just ended, and the PC's Continue watching row, where a card starts on the PC with one tap.
class _Nothing extends StatefulWidget {
  const _Nothing({
    required this.link,
    required this.stopped,
    required this.resuming,
    required this.onResume,
    this.onBrowseLibrary,
    this.onPlayOnPc,
    this.changed,
  });
  final RemoteLink link;

  /// The video Stop ended, to play again from where it was; null when there is none.
  final ({String id, String title, int positionMs, QueueRef? queue})? stopped;
  final bool resuming;
  final VoidCallback onResume;
  final VoidCallback? onBrowseLibrary;
  final Future<String?> Function(LibraryEntry entry)? onPlayOnPc;
  final Listenable? changed;

  @override
  State<_Nothing> createState() => _NothingState();
}

class _NothingState extends State<_Nothing> {
  List<LibraryEntry> _continuing = const [];
  String? _starting;
  bool _wasConnected = false;
  int _loads = 0;

  RemoteLink get link => widget.link;

  // The row shows for a PC with a library that lets phones start videos on it.
  bool get _offers => widget.onPlayOnPc != null && link.features.contains('library') && link.canStart;

  @override
  void initState() {
    super.initState();
    link.addListener(_linkChanged);
    widget.changed?.addListener(_load);
    _wasConnected = link.status.isConnected;
    unawaited(_load());
  }

  @override
  void didUpdateWidget(_Nothing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.changed != widget.changed) {
      oldWidget.changed?.removeListener(_load);
      widget.changed?.addListener(_load);
    }
    if (oldWidget.link != link) {
      oldWidget.link.removeListener(_linkChanged);
      link.addListener(_linkChanged);
      _wasConnected = link.status.isConnected;
      _continuing = const [];
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    link.removeListener(_linkChanged);
    widget.changed?.removeListener(_load);
    super.dispose();
  }

  void _linkChanged() {
    final connected = link.status.isConnected;
    if (connected && !_wasConnected) unawaited(_load());
    _wasConnected = connected;
  }

  // Home's first page starts with Continue watching. A load that fails leaves the row as it was.
  Future<void> _load() async {
    if (!_offers || !link.status.isConnected) return;
    final load = ++_loads;
    final home = LibraryListing(link, const BrowseRequest(home: true));
    await home.load();
    final entries = home.error == null ? home.entries.where((e) => e.homeSection == 'continue' && e.playable).toList() : null;
    home.dispose();
    if (!mounted || load != _loads || entries == null) return;
    setState(() => _continuing = entries);
  }

  Future<void> _play(LibraryEntry entry) async {
    if (_starting != null) return;
    setState(() => _starting = entry.id);
    final error = await widget.onPlayOnPc!(entry);
    if (!mounted) return;
    setState(() => _starting = null);
    if (error != null) {
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error), duration: const Duration(seconds: 4)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = link.status.isConnected;
    final stopped = connected ? widget.stopped : null;
    final browse = widget.onBrowseLibrary != null && link.features.contains('library');
    final row = connected && _offers ? _continuing : const <LibraryEntry>[];
    return Padding(
      padding: EdgeInsets.only(top: row.isEmpty ? 40 : 20),
      child: Column(
        children: [
          Well(
            width: 96,
            height: 96,
            child: const Center(child: Icon(Icons.movie_outlined, size: 38, color: Palette.muted)),
          ),
          const SizedBox(height: 22),
          Text('Nothing is playing', textAlign: TextAlign.center, style: display(24)),
          const SizedBox(height: 8),
          Text(
            connected ? 'Start a video on ${link.pcName} and its controls appear here.' : 'When ${link.pcName} plays something, its controls appear here.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Palette.muted, fontSize: 14.5, height: 1.4),
          ),
          if (stopped != null) ...[
            const SizedBox(height: 20),
            PebbleButton(
              label: widget.resuming ? 'Starting…' : 'Resume ${stopped.title} · ${formatClock(stopped.positionMs)}',
              icon: Icons.play_arrow_rounded,
              lit: true,
              onTap: widget.resuming ? null : widget.onResume,
            ),
          ],
          if (browse) ...[
            SizedBox(height: stopped != null ? 10 : 20),
            PebbleButton(label: 'Browse library', icon: Icons.video_library_outlined, lit: stopped == null, onTap: widget.onBrowseLibrary),
          ],
          if (row.isNotEmpty) ...[
            const SizedBox(height: 26),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Continue on ${link.pcName}', maxLines: 1, overflow: TextOverflow.ellipsis, style: display(19)),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: ContinueCard.heightOf(context),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: row.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final entry = row[index];
                  final starting = _starting == entry.id;
                  return Stack(
                    children: [
                      Opacity(
                        opacity: _starting != null && !starting ? 0.5 : 1,
                        child: ContinueCard(link: link, entry: entry, onOpen: (entry) => unawaited(_play(entry))),
                      ),
                      // Over the card's picture while the PC starts it.
                      if (starting)
                        const Positioned(
                          left: 0,
                          right: 0,
                          top: 0,
                          height: 130,
                          child: IgnorePointer(
                            child: Center(child: SizedBox(width: 30, height: 30, child: CircularProgressIndicator(color: Palette.accent, strokeWidth: 2.5))),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One of the buttons under the play buttons: an icon over a short label, lit with the accent while its mode is on.
class _ModeButton extends StatelessWidget {
  const _ModeButton({required this.label, required this.semanticLabel, required this.icon, this.active = false, required this.enabled, required this.onTap});
  final String label;
  final String semanticLabel;
  final IconData icon;
  final bool active;
  final bool enabled;
  final VoidCallback onTap;

  @override
  // An icon and a line of text in a 52 dp pebble: past 130% text they would spill out of it.
  Widget build(BuildContext context) => MediaQuery.withClampedTextScaling(
    maxScaleFactor: 1.3,
    child: Pebble(
      height: 52,
      radius: 16,
      enabled: enabled,
      onTap: onTap,
      semanticLabel: semanticLabel,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: active ? Palette.accent : null),
          const SizedBox(height: 3),
          // Five of them share a narrow phone's width: the word shrinks a little rather than being cut off.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              style: TextStyle(fontSize: 11.5, height: 1.15, fontWeight: FontWeight.w500, color: active ? Palette.accent : null),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Where the PC's sound plays, beside Audio and Subtitles: a tap plays it on this phone, and another gives it back to
/// the PC.
class _SoundPill extends StatelessWidget {
  const _SoundPill({required this.sound, required this.elsewhere, required this.enabled, required this.onToggle});
  final PhoneSound sound;

  /// Another phone has the sound now.
  final bool elsewhere;
  final bool enabled;
  final VoidCallback onToggle;

  @override
  // Two lines of text in a 54 dp pebble: past 160% text they would spill out of it.
  Widget build(BuildContext context) => MediaQuery.withClampedTextScaling(
    maxScaleFactor: 1.6,
    child: ListenableBuilder(
      listenable: sound,
      builder: (context, _) {
        final on = sound.on;
        final where = on ? 'On this phone' : (elsewhere ? 'On a phone' : 'On the PC');
        // A third of the row's width holds "On phone" whole, where "On this phone" was cut short.
        final shown = on ? 'On phone' : where;
        return Pebble(
          height: 54,
          radius: 18,
          enabled: enabled,
          onTap: onToggle,
          semanticLabel: on ? 'Sound, On this phone. Play it on the PC' : 'Sound, $where. Play it on this phone',
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(on ? Icons.headphones_rounded : Icons.speaker_rounded, size: 20, color: on ? Palette.accent : null),
              const SizedBox(width: 7),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Sound', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, height: 1.15)),
                    Text(
                      shown,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, height: 1.2, fontWeight: FontWeight.w500, color: on ? Palette.accent : Palette.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

/// Under the pills while this phone plays the PC's sound: how it is going, and the delay that lines it up with the
/// picture, for headphones and speakers that take their own time (each step 50 ms, kept for next time).
class _SoundDelay extends StatelessWidget {
  const _SoundDelay({required this.sound});
  final PhoneSound sound;

  static String _delay(int ms) {
    if (ms == 0) return 'Sound delay: none';
    final seconds = (ms.abs() / 1000).toStringAsFixed(2);
    return ms > 0 ? 'Sound $seconds s later' : 'Sound $seconds s earlier';
  }

  @override
  Widget build(BuildContext context) => MediaQuery.withClampedTextScaling(
    maxScaleFactor: 1.6,
    child: ListenableBuilder(
      listenable: Listenable.merge([sound, sound.settings]),
      builder: (context, _) {
        final delay = sound.settings.soundDelayMs;
        final limit = AppSettings.soundDelayLimitMs;
        return Slab(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          radius: 18,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(sound.statusText, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, height: 1.2)),
                    Text(
                      _delay(delay),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, height: 1.25, color: Palette.muted, fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Pebble(
                width: 40,
                height: 40,
                tapArea: Pebble.fingertip,
                enabled: delay > -limit,
                onTap: () => unawaited(sound.adjustDelay(-50)),
                semanticLabel: 'Sound earlier',
                child: const Icon(Icons.remove_rounded, size: 20),
              ),
              Pebble(
                width: 40,
                height: 40,
                tapArea: Pebble.fingertip,
                enabled: delay < limit,
                onTap: () => unawaited(sound.adjustDelay(50)),
                semanticLabel: 'Sound later',
                child: const Icon(Icons.add_rounded, size: 20),
              ),
            ],
          ),
        );
      },
    ),
  );
}

/// Audio or Subtitles with the PC's choice under it, opening the tracks sheet. The choice is cut short rather than
/// shrunk: a language can be long.
class _TrackPill extends StatelessWidget {
  const _TrackPill({
    required this.label,
    required this.icon,
    this.opened = false,
    required this.tracks,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final List<RemoteTrack> tracks;

  /// The video has opened on the PC, so an empty list means none rather than not yet.
  final bool opened;
  final int? selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  // As the Sound pill: two lines in a 54 dp pebble.
  Widget build(BuildContext context) => MediaQuery.withClampedTextScaling(maxScaleFactor: 1.6, child: Builder(builder: _build));

  Widget _build(BuildContext context) {
    final choice = tracks.where((t) => t.id == selected).firstOrNull;
    final value = choice == null
        ? (tracks.isEmpty && !opened ? 'Not yet' : 'None')
        : choice.id == RemoteTrack.off
        ? 'Off'
        // Two tracks in one language are told apart by their detail, as in the sheet.
        : choice.detail != null && tracks.where((t) => t.name == choice.name).length > 1
        ? '${choice.name} · ${choice.detail}'
        : choice.name;
    final active = choice != null && choice.id != RemoteTrack.off;
    return Pebble(
      height: 54,
      radius: 18,
      enabled: enabled,
      onTap: onTap,
      semanticLabel: '$label, $value',
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: active ? Palette.accent : null),
          const SizedBox(width: 7),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, height: 1.15)),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.2,
                    fontWeight: FontWeight.w500,
                    color: active ? Palette.accent : Palette.muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The timeline: a well with an accent fill and a knob. Tap or drag; the seek is sent on release.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.fraction, required this.enabled, required this.onDrag, required this.onRelease, required this.onCancel});
  final double fraction;
  final bool enabled;
  final ValueChanged<double> onDrag;
  final ValueChanged<double> onRelease;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    // Measured when touched, not with a LayoutBuilder, so the screen can ask for its intrinsic height.
    double at(Offset local) => (local.dx / math.max(1.0, context.size?.width ?? 1)).clamp(0.0, 1.0);
    return Semantics(
      slider: true,
      enabled: enabled,
      label: 'Timeline',
      value: '${(fraction * 100).round()}%',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: enabled ? (d) => onDrag(at(d.localPosition)) : null,
        onHorizontalDragUpdate: enabled ? (d) => onDrag(at(d.localPosition)) : null,
        // Where the finger left, not [fraction]: a drag can end in the same frame as its last move, before a rebuild.
        onHorizontalDragEnd: enabled ? (d) => onRelease(at(d.localPosition)) : null,
        onHorizontalDragCancel: enabled ? onCancel : null,
        onTapUp: enabled ? (d) => onRelease(at(d.localPosition)) : null,
        // The bar is 10 dp; the touch takes 44 around it.
        child: SizedBox(
          height: 44,
          child: Opacity(
            opacity: enabled ? 1 : 0.5,
            child: CustomPaint(
              painter: _TrackPainter(fraction: fraction, height: 10, fill: Palette.accent, glow: true, knob: 18),
            ),
          ),
        ),
      ),
    );
  }
}

class _VolumeTrack extends StatelessWidget {
  const _VolumeTrack({
    required this.value,
    required this.muted,
    this.label = 'PC volume',
    required this.enabled,
    required this.onChanged,
    required this.onChangeEnd,
  });
  final int value;
  final bool muted;
  final String label;
  final bool enabled;
  final ValueChanged<int> onChanged;
  final ValueChanged<int> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    int at(Offset local) => ((local.dx / math.max(1.0, context.size?.width ?? 1)).clamp(0.0, 1.0) * 100).round();
    return Semantics(
      slider: true,
      enabled: enabled,
      label: label,
      value: '$value%',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: enabled ? (d) => onChanged(at(d.localPosition)) : null,
        onHorizontalDragUpdate: enabled ? (d) => onChanged(at(d.localPosition)) : null,
        onHorizontalDragEnd: enabled ? (d) => onChangeEnd(at(d.localPosition)) : null,
        onTapUp: enabled ? (d) => onChangeEnd(at(d.localPosition)) : null,
        child: SizedBox(
          height: 48,
          child: Opacity(
            opacity: enabled ? 1 : 0.5,
            child: CustomPaint(
              painter: _TrackPainter(
                fraction: value / 100,
                height: 8,
                fill: muted ? Palette.muted.withValues(alpha: 0.45) : Palette.ink.withValues(alpha: 0.85),
                knob: 0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TrackPainter extends CustomPainter {
  _TrackPainter({required this.fraction, required this.height, required this.fill, this.glow = false, required this.knob});
  final double fraction;
  final double height;
  final Color fill;
  final bool glow;
  final double knob;

  @override
  void paint(Canvas canvas, Size size) {
    final top = (size.height - height) / 2;
    final track = RRect.fromLTRBR(0, top, size.width, top + height, Radius.circular(height / 2));
    // The well: dark, with a shadow along the top inside edge.
    canvas.drawRRect(track, Paint()..color = Palette.well);
    canvas.save();
    canvas.clipRRect(track);
    canvas.drawRRect(
      track.shift(Offset(0, -height * 0.55)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.7)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.restore();
    final f = fraction.clamp(0.0, 1.0);
    final fillWidth = math.max(height, size.width * f);
    if (f > 0) {
      final filled = RRect.fromLTRBR(0, top, fillWidth, top + height, Radius.circular(height / 2));
      if (glow) {
        canvas.drawRRect(
          filled,
          Paint()
            ..color = fill.withValues(alpha: 0.5)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
        );
      }
      canvas.drawRRect(filled, Paint()..color = fill);
    }
    if (knob > 0) {
      final cx = (size.width * f).clamp(knob / 2, size.width - knob / 2);
      final center = Offset(cx, size.height / 2);
      canvas.drawCircle(
        center.translate(0, 2),
        knob / 2,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.6)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
      canvas.drawCircle(center, knob / 2, Paint()..color = Palette.knob);
    }
  }

  @override
  bool shouldRepaint(_TrackPainter old) => old.fraction != fraction || old.fill != fill || old.height != height;
}

/// The artwork area as a touch pad: tap toggles, a sideways swipe seeks ±10 s, sliding up and down sets the volume.
class _TouchPad extends StatefulWidget {
  const _TouchPad({
    required this.enabled,
    required this.volumeEnabled,
    required this.feedback,
    required this.onTap,
    required this.onSwipe,
    required this.volume,
    required this.onVolume,
  });
  final bool enabled;
  final bool volumeEnabled;
  final String? feedback;
  final VoidCallback onTap;
  final ValueChanged<bool> onSwipe;
  final int Function() volume;
  final void Function(int value, bool done) onVolume;

  @override
  State<_TouchPad> createState() => _TouchPadState();
}

class _TouchPadState extends State<_TouchPad> {
  double _travelX = 0, _travelY = 0;
  double _startVolume = 0;
  int _lastVolume = 0;

  // Separate horizontal and vertical recognizers, not one pan: the pad's own vertical drag then wins over the page's
  // scrolling, so sliding up and down changes the volume instead of scrolling the screen.
  void _horizontalStart(DragStartDetails details) => _travelX = 0;
  void _horizontalUpdate(DragUpdateDetails details) => _travelX += details.delta.dx;
  void _horizontalEnd(DragEndDetails details) {
    final fast = (details.primaryVelocity ?? 0).abs() > 400;
    if (_travelX.abs() > 48 || fast) {
      HapticFeedback.lightImpact();
      widget.onSwipe((_travelX == 0 ? (details.primaryVelocity ?? 0) : _travelX) > 0);
    }
  }

  void _verticalStart(DragStartDetails details) {
    _travelY = 0;
    _startVolume = widget.volume().toDouble();
    _lastVolume = widget.volume();
  }

  void _verticalUpdate(DragUpdateDetails details) {
    _travelY += details.delta.dy;
    // A full sweep of the pad's height covers the whole range.
    final height = math.max(80.0, context.size?.height ?? 200);
    final value = (_startVolume - _travelY / height * 100).round().clamp(0, 100);
    if (value != _lastVolume) {
      _lastVolume = value;
      widget.onVolume(value, false);
    }
  }

  void _verticalEnd(DragEndDetails details) => widget.onVolume(_lastVolume, true);

  @override
  Widget build(BuildContext context) {
    final hintStyle = TextStyle(color: Colors.white.withValues(alpha: 0.72), fontSize: 12);
    return Semantics(
      label: 'Touch pad. Tap to play or pause, swipe sideways to skip 10 seconds, slide up or down for volume.',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled
            ? () {
                HapticFeedback.lightImpact();
                widget.onTap();
              }
            : null,
        onHorizontalDragStart: widget.enabled ? _horizontalStart : null,
        onHorizontalDragUpdate: widget.enabled ? _horizontalUpdate : null,
        onHorizontalDragEnd: widget.enabled ? _horizontalEnd : null,
        onVerticalDragStart: widget.volumeEnabled ? _verticalStart : null,
        onVerticalDragUpdate: widget.volumeEnabled ? _verticalUpdate : null,
        onVerticalDragEnd: widget.volumeEnabled ? _verticalEnd : null,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: const RadialGradient(
              center: Alignment(-0.4, -0.6),
              radius: 1.25,
              colors: [Color(0xFF3D6B7A), Color(0xFF11222B)],
              stops: [0, 0.7],
            ),
            boxShadow: const [BoxShadow(color: Color(0x59000000), blurRadius: 10, offset: Offset(0, 4))],
          ),
          child: Stack(
            children: [
              // The ring sits in the space above the hints, so the two never overlap on a short pad.
              Positioned.fill(
                bottom: 34,
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: widget.feedback != null
                        ? Container(
                            key: ValueKey(widget.feedback),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(99)),
                            child: Text(
                              widget.feedback!,
                              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                          )
                        : CustomPaint(
                            key: const ValueKey('ring'),
                            painter: _DashedRing(color: Colors.white.withValues(alpha: widget.enabled ? 0.35 : 0.18)),
                            child: SizedBox(
                              width: 62,
                              height: 62,
                              child: Center(
                                child: Text(
                                  'tap',
                                  style: TextStyle(color: Colors.white.withValues(alpha: widget.enabled ? 0.75 : 0.35), fontSize: 12),
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
              ),
              Positioned(
                left: 14,
                right: 14,
                bottom: 12,
                child: Opacity(
                  opacity: widget.enabled ? 1 : 0.45,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Narrow phones and large text sizes shrink the hints rather than overflowing the pad.
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('« −10 s', style: hintStyle),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        flex: 2,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('slide ↕ volume', style: hintStyle),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('+10 s »', style: hintStyle),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashedRing extends CustomPainter {
  _DashedRing({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final radius = size.shortestSide / 2 - 1;
    final center = size.center(Offset.zero);
    const dashes = 22;
    for (var i = 0; i < dashes; i++) {
      final start = i * 2 * math.pi / dashes;
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius), start, math.pi / dashes, false, paint);
    }
  }

  @override
  bool shouldRepaint(_DashedRing old) => old.color != color;
}
