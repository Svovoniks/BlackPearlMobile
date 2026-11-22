import 'dart:async';
import 'dart:ui' show DisplayFeatureType;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../playback/phone_playback.dart';
import '../playback/picture_in_picture.dart';
import '../playback/track_languages.dart';
import '../protocol/library.dart' show qualityLabel;
import '../storage/app_settings.dart';
import 'pebbles.dart';
import 'player_dock.dart';
import 'player_options.dart';
import 'theme.dart';

/// The phone's own player, full screen. Leaving it stops the video here and saves where it got to on the PC.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.playback, required this.pcName, this.settings, this.onHandedToPc});
  final PhonePlayback playback;
  final String pcName;

  /// Where Loop is kept between videos.
  final AppSettings? settings;

  /// The PC took the video over; the app shows the Remote.
  final VoidCallback? onHandedToPc;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> with WidgetsBindingObserver {
  static const MethodChannel _display = MethodChannel('blackpearl/display');

  // The camera cutout's safe insets from Android, in logical pixels.
  EdgeInsets _cutout = EdgeInsets.zero;

  Future<void> _readCutout() async {
    try {
      final values = await _display.invokeMapMethod<String, int>('cutout');
      if (values == null || !mounted) return;
      final ratio = MediaQuery.devicePixelRatioOf(context);
      double at(String side) => (values[side] ?? 0) / ratio;
      final cutout = EdgeInsets.fromLTRB(at('left'), at('top'), at('right'), at('bottom'));
      if (cutout != _cutout) setState(() => _cutout = cutout);
    } on PlatformException {
      // No window to ask.
    } on MissingPluginException {
      // Not on Android.
    }
  }

  // Turning the phone moves the cutout to another edge.
  @override
  void didChangeMetrics() => WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_readCutout()));

  VideoController? _controller;
  Player? _player;
  String? _noteShown;
  bool _handing = false;
  final List<StreamSubscription<Object?>> _playerSubscriptions = [];

  PhonePlayback get playback => widget.playback;
  PictureInPicture get pip => PictureInPicture.instance;

  @override
  void initState() {
    super.initState();
    playback.loopMode = widget.settings?.loopMode ?? playback.loopMode;
    playback.shuffle = widget.settings?.shuffle ?? playback.shuffle;
    playback.addListener(_changed);
    playback.notice.addListener(_notice);
    playback.pending.addListener(_rebuild);
    playback.upNext.addListener(_rebuild);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_readCutout()));
    pip.active.addListener(_pipChanged);
    pip.onToggle = _toggle;
    pip.onDismissed = _pipDismissed;
    pip.onShown = playback.pictureInPictureShown;
    pip.onReady = _syncPip;
    // The app may have started without a window to ask whether picture in picture is there.
    unawaited(
      pip.refresh().then((_) {
        if (mounted) {
          _syncPip();
          setState(() {});
        }
      }),
    );
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    _changed();
  }

  @override
  void dispose() {
    for (final subscription in _playerSubscriptions) {
      unawaited(subscription.cancel());
    }
    WidgetsBinding.instance.removeObserver(this);
    pip.active.removeListener(_pipChanged);
    if (pip.onToggle == _toggle) pip.onToggle = null;
    if (pip.onDismissed == _pipDismissed) pip.onDismissed = null;
    if (pip.onShown == playback.pictureInPictureShown) pip.onShown = null;
    if (pip.onReady == _syncPip) pip.onReady = null;
    // Leaving the player: leaving the app no longer moves anything to a small window.
    unawaited(pip.update(wanted: false));
    playback.removeListener(_changed);
    playback.notice.removeListener(_notice);
    playback.pending.removeListener(_rebuild);
    playback.upNext.removeListener(_rebuild);
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    unawaited(SystemChrome.setPreferredOrientations([]));
    _hideTimer?.cancel();
    _rippleTimer?.cancel();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _changed() {
    final player = playback.player;
    if (!identical(player, _player)) {
      _player = player;
      _controller = player == null ? null : VideoController(player);
      // A new player gets a new picture, whose subtitles start where they rest.
      _videoKey = GlobalKey<VideoState>();
      _subtitleLift = -1;
      for (final subscription in _playerSubscriptions) {
        unawaited(subscription.cancel());
      }
      _playerSubscriptions.clear();
      if (player != null) {
        void sync(Object? _) => _syncPip();
        void tracks(Object? _) => unawaited(_readTracks());
        _playerSubscriptions
          ..add(player.stream.playing.listen(sync))
          ..add(player.stream.playing.listen((_) => _playingChanged()))
          ..add(player.stream.width.listen(sync))
          ..add(player.stream.height.listen(sync))
          ..add(player.stream.tracks.listen(tracks))
          ..add(player.stream.track.listen(tracks));
        unawaited(_readTracks());
      }
      _syncPip();
    } else {
      // Another conversion of the same video, as after another audio track was picked, plays on the same player.
      unawaited(_readTracks());
    }
    final note = playback.stream?.note;
    if (note != null && note != _noteShown) {
      _noteShown = note;
      WidgetsBinding.instance.addPostFrameCallback((_) => _say(note));
    }
    if (mounted) setState(() {});
  }

  void _pipChanged() {
    // Back from the small window the picture is new, with its subtitles where they rest: place them again.
    _subtitleLift = -1;
    if (mounted) setState(() {});
  }

  // The window's button: the user is watching the window, so nothing waits to resume.
  void _toggle() {
    playback.pictureInPictureShown();
    unawaited(_player?.playOrPause());
  }

  // Closing the small window stops the video; it doesn't start again by itself when the app is next opened.
  void _pipDismissed() => unawaited(playback.pictureInPictureClosed());

  // While a video plays, leaving the app moves it to a small window, shaped like the video.
  void _syncPip() {
    final player = _player;
    final state = player?.state;
    unawaited(
      pip.update(
        wanted: state?.playing ?? false,
        width: (state?.width ?? 0) > 0 ? state!.width! : 16,
        height: (state?.height ?? 0) > 0 ? state!.height! : 9,
        playing: state?.playing ?? false,
      ),
    );
  }

  void _notice() {
    final text = playback.notice.value;
    if (text != null) _say(text);
  }

  void _say(String text, {Duration duration = const Duration(seconds: 6)}) {
    if (!mounted) return;
    // Above the dock, so a message never covers its buttons.
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    final dock = _dockKey.currentContext?.findRenderObject() as RenderBox?;
    double? above;
    if (stack != null && dock != null && stack.hasSize && dock.hasSize) {
      above = stack.size.height - dock.localToGlobal(Offset.zero, ancestor: stack).dy + 8;
    }
    final side = MediaQuery.sizeOf(context).width > 640 ? (MediaQuery.sizeOf(context).width - 560) / 2 : 16.0;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          duration: duration,
          margin: above == null ? null : EdgeInsets.fromLTRB(side, 0, side, above),
        ),
      );
  }

  // Leaving pops the screen; whoever opened it then stops the phone's player, once its picture is off screen.
  void _leave() => Navigator.of(context).pop();

  Future<void> _continueOnPc() async {
    if (_handing) return;
    setState(() => _handing = true);
    final error = await playback.continueOnPc();
    if (!mounted) return;
    setState(() => _handing = false);
    if (error != null) {
      _say(error);
      return;
    }
    widget.onHandedToPc?.call();
    Navigator.of(context).pop();
  }

  void _options([PlayerOptionsTab tab = PlayerOptionsTab.audio]) {
    if (playback.player == null || playback.stream == null) return;
    unawaited(showPlayerOptions(context, playback, tab: tab));
  }

  // Loop cycles as on the PC: off, all, one.
  void _cycleLoop() {
    final next = switch (playback.loopMode) {
      'off' => 'all',
      'all' => 'one',
      _ => 'off',
    };
    playback.loopMode = next;
    setState(() {});
    unawaited(widget.settings?.setLoopMode(next));
    _say(switch (next) {
      'all' =>
        playback.shuffle && playback.inList
            ? 'Loop all: Shuffle starts a new round once every episode has played.'
            : playback.stream?.next != null || playback.stream?.first != null
            ? 'Loop all: the show starts again after its last episode.'
            : 'Loop all: the video plays again when it ends.',
      'one' => 'Loop one: this video plays again when it ends.',
      _ => 'Loop off.',
    }, duration: const Duration(seconds: 2));
  }

  void _seekBy(int seconds) {
    final player = _player;
    if (player == null) return;
    final duration = player.state.duration;
    var target = player.state.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    unawaited(player.seek(target));
  }

  // ---- The controls: shown on a tap, hidden again 3 seconds after the last touch while the video plays ----

  bool _controlsShown = true;
  Timer? _hideTimer;
  DockMenu? _menu;
  bool _dragging = false;
  final Map<DockMenu, GlobalKey> _chipKeys = {for (final menu in DockMenu.values) menu: GlobalKey()};
  final GlobalKey _dockKey = GlobalKey();
  final GlobalKey _stackKey = GlobalKey();
  GlobalKey<VideoState> _videoKey = GlobalKey<VideoState>();

  // The tracks playing now, by id, read from libmpv when they change.
  String? _audioId, _subtitleId;

  Future<void> _readTracks() async {
    final selected = await playback.selectedTracks();
    if (!mounted) return;
    if (selected.audio != _audioId || selected.subtitle != _subtitleId) {
      setState(() {
        _audioId = selected.audio;
        _subtitleId = selected.subtitle;
      });
    }
  }

  bool get _playing => _player?.state.playing ?? false;

  void _showControls() {
    if (!_controlsShown) setState(() => _controlsShown = true);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_playing || _menu != null || _dragging) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || !_playing || _menu != null || _dragging || playback.upNext.value != null) return;
      setState(() => _controlsShown = false);
    });
  }

  void _playingChanged() {
    if (!mounted) return;
    // Paused, the controls stay; playing again, they hide after a while.
    if (_playing) {
      _scheduleHide();
    } else {
      _hideTimer?.cancel();
      if (!_controlsShown) setState(() => _controlsShown = true);
    }
    _rebuild();
  }

  void _tapped() {
    if (_menu != null) {
      _closeMenu();
      return;
    }
    if (_controlsShown) {
      _hideTimer?.cancel();
      setState(() => _controlsShown = false);
    } else {
      _showControls();
    }
  }

  // Double-tapping a side seeks 10 seconds that way; taps in a row add up.
  double _doubleTapX = 0;
  int _rippleSeconds = 0;
  Timer? _rippleTimer;

  void _doubleTapped() {
    final width = MediaQuery.sizeOf(context).width;
    final forward = _doubleTapX > width / 2;
    final seconds = forward ? 10 : -10;
    _seekBy(seconds);
    setState(() => _rippleSeconds = _rippleSeconds != 0 && (_rippleSeconds > 0) == forward ? _rippleSeconds + seconds : seconds);
    _rippleTimer?.cancel();
    _rippleTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _rippleSeconds = 0);
    });
  }

  void _openMenu(DockMenu menu) {
    _hideTimer?.cancel();
    setState(() {
      _menu = _menu == menu ? null : menu;
      _controlsShown = true;
    });
    if (_menu == null) _scheduleHide();
  }

  void _closeMenu() {
    if (_menu == null) return;
    setState(() => _menu = null);
    _scheduleHide();
  }

  void _toggleShuffle() {
    final on = !playback.shuffle;
    playback.shuffle = on;
    unawaited(widget.settings?.setShuffle(on));
    _say(on ? 'Shuffle on: every episode plays once, in a random order.' : 'Shuffle off: episodes play in order.', duration: const Duration(seconds: 2));
    _showControls();
  }

  // ---- What the chips show and their menus offer ----

  ({List<AudioTrack> tracks, List<TrackLabel> labels}) get _audio {
    final tracks = playback.audioTracks;
    return (tracks: tracks, labels: audioLabels(tracks));
  }

  // The audio track to tick: one a conversion is switching to, or the one playing.
  String? get _tickedAudio => playback.pending.value?.audio ?? _audioId;

  ({List<SubtitleTrack> tracks, List<TrackLabel> labels}) get _subtitles {
    final tracks = PhonePlayback.subtitleChoices(_player?.state.tracks ?? const Tracks());
    return (tracks: tracks, labels: subtitleLabels(tracks));
  }

  // A chip names the track; two of the same name add what tells them apart, such as SDH, or their number.
  static String _chipName(TrackLabel label, List<TrackLabel> all) {
    final twins = all.where((other) => other.name == label.name && !identical(other, label)).toList();
    if (twins.isEmpty) return label.name;
    final parts = label.detail?.split(' · ') ?? const <String>[];
    // The first part of the detail no other one of that name has; the PC numbers twins whose details are the same.
    final telling = parts.where((part) => twins.every((twin) => !(twin.detail?.split(' · ').contains(part) ?? false))).firstOrNull;
    return telling == null ? label.name : '${label.name} $telling';
  }

  static String _shortQuality(String quality) => switch (quality) {
    'original' => 'Original',
    _ => qualityLabel(quality),
  };

  DockChipValue get _audioChip {
    final audio = _audio;
    if (audio.tracks.isEmpty) return const DockChipValue('Audio', off: true);
    final at = audio.tracks.length == 1 ? 0 : audio.tracks.indexWhere((t) => t.id == _tickedAudio);
    return at < 0
        ? const DockChipValue('Audio', off: true)
        : DockChipValue(_chipName(audio.labels[at], audio.labels), busy: playback.pending.value?.audio != null);
  }

  DockChipValue get _subtitleChip {
    final subtitles = _subtitles;
    final at = subtitles.tracks.indexWhere((t) => t.id == _subtitleId);
    return at < 0 ? const DockChipValue('Off', off: true) : DockChipValue(_chipName(subtitles.labels[at], subtitles.labels));
  }

  DockChipValue? get _qualityChip {
    final stream = playback.stream;
    if (stream == null || stream.qualities.length < 2) return null;
    final switching = playback.pending.value?.quality;
    return switching != null ? DockChipValue(_shortQuality(switching), busy: true) : DockChipValue(_shortQuality(stream.quality));
  }

  ChipMenuCard _menuCard(DockMenu menu, double maxHeight) {
    void pick(Future<void> Function() change) {
      _closeMenu();
      unawaited(change().then((_) => _readTracks()));
    }

    void all(PlayerOptionsTab tab) {
      _closeMenu();
      _options(tab);
    }

    switch (menu) {
      case DockMenu.audio:
        final audio = _audio;
        return ChipMenuCard(
          title: 'Audio',
          maxHeight: maxHeight,
          options: [
            for (var i = 0; i < audio.tracks.length; i++)
              ChipMenuOption(
                name: audio.labels[i].name,
                detail: audio.labels[i].detail,
                selected: audio.tracks[i].id == _tickedAudio || audio.tracks.length == 1,
                onTap: () => pick(() => playback.chooseAudio(audio.tracks[i])),
              ),
          ],
          onAllOptions: () => all(PlayerOptionsTab.audio),
        );
      case DockMenu.subtitles:
        final subtitles = _subtitles;
        return ChipMenuCard(
          title: 'Subtitles',
          maxHeight: maxHeight,
          options: [
            ChipMenuOption(name: 'Off', selected: _subtitleId == null, onTap: () => pick(() => playback.chooseSubtitle(null))),
            for (var i = 0; i < subtitles.tracks.length; i++)
              ChipMenuOption(
                name: subtitles.labels[i].name,
                detail: subtitles.labels[i].detail,
                selected: subtitles.tracks[i].id == _subtitleId,
                onTap: () => pick(() => playback.chooseSubtitle(subtitles.tracks[i])),
              ),
          ],
          onAllOptions: () => all(PlayerOptionsTab.subtitles),
        );
      case DockMenu.quality:
        final stream = playback.stream;
        final switching = playback.pending.value?.quality;
        return ChipMenuCard(
          title: 'Quality',
          maxHeight: maxHeight,
          options: [
            for (final quality in stream?.qualities ?? const <String>[])
              ChipMenuOption(
                name: qualityLabel(quality),
                selected: switching == null ? stream?.quality == quality : switching == quality,
                busy: switching == quality,
                onTap: () {
                  _closeMenu();
                  unawaited(playback.changeQuality(quality));
                },
              ),
          ],
          onAllOptions: () => all(PlayerOptionsTab.quality),
        );
    }
  }

  // Subtitles move up while the dock shows, rather than sit under it.
  double _subtitleLift = -1;

  void _placeSubtitles(bool shown) {
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    final dock = _dockKey.currentContext?.findRenderObject() as RenderBox?;
    var lift = 24.0;
    if (shown && stack != null && dock != null && stack.hasSize && dock.hasSize) {
      final top = dock.localToGlobal(Offset.zero, ancestor: stack).dy;
      lift = stack.size.height - top + 12;
    }
    if (lift == _subtitleLift) return;
    _subtitleLift = lift;
    _videoKey.currentState?.setSubtitleViewPadding(EdgeInsets.fromLTRB(16, 0, 16, lift), duration: const Duration(milliseconds: 150));
  }

  @override
  Widget build(BuildContext context) {
    final stream = playback.stream;
    final controller = _controller;
    final player = _player;
    final title = stream?.title ?? 'Opening…';
    final size = MediaQuery.sizeOf(context);
    final portrait = size.height > size.width;
    final narrow = size.width < 600;
    // The controls keep clear of the camera cutout and the rounded corners; the picture may go under them.
    final safe = controlInsets(MediaQuery.of(context), cutout: _cutout);
    final inPip = pip.active.value;
    final pending = playback.pending.value;
    final upNext = playback.upNext.value;
    final shown = _controlsShown || upNext != null || _menu != null;
    final side = portrait ? 14.0 : 22.0;

    Widget body() {
      final topBar = Row(
        children: [
          Pebble(width: 44, height: 44, onTap: _leave, semanticLabel: 'Back', child: const Icon(Icons.arrow_back_rounded)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: display(portrait ? 19 : 20)),
                if (stream?.detail != null)
                  Text(
                    stream!.detail!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Color(0xC7FFFFFF), fontSize: 12.5),
                  ),
              ],
            ),
          ),
          if (pip.supported) ...[
            const SizedBox(width: 10),
            Pebble(
              width: 44,
              height: 44,
              onTap: () => unawaited(pip.enter()),
              semanticLabel: 'Picture in picture',
              child: const Icon(Icons.picture_in_picture_alt_rounded, size: 21),
            ),
          ],
          const SizedBox(width: 10),
          Tooltip(
            message: 'Continue on ${widget.pcName}',
            child: Pebble(
              height: 44,
              width: narrow ? 44 : null,
              enabled: !_handing && stream != null,
              onTap: _continueOnPc,
              semanticLabel: 'Continue on ${widget.pcName}',
              padding: narrow ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 16),
              // In portrait the title needs the room; the button keeps its place as an icon.
              child: narrow
                  ? (_handing
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Palette.ink))
                        : const Icon(Icons.desktop_windows_outlined, size: 20))
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.desktop_windows_outlined, size: 19),
                        const SizedBox(width: 8),
                        Text(_handing ? 'Starting…' : 'Continue on PC', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      ],
                    ),
            ),
          ),
        ],
      );

      Widget timeline() => _LiveTimeline(
        player: player!,
        portrait: portrait && upNext == null,
        onSeek: (to) => unawaited(player.seek(to)),
        onDragging: (dragging) {
          _dragging = dragging;
          if (dragging) {
            _hideTimer?.cancel();
          } else {
            _scheduleHide();
          }
        },
      );

      final Widget dock = upNext != null
          ? _UpNextLive(
              offer: upNext,
              portrait: portrait,
              timeline: timeline(),
              onPlay: () => unawaited(playback.playUpNext()),
              onCancel: () {
                playback.cancelUpNext();
                _showControls();
              },
            )
          : PlayerDock(
              portrait: portrait,
              timeline: timeline(),
              playing: _playing,
              onPlayPause: () {
                unawaited(player!.playOrPause());
                _showControls();
              },
              onBack10: () {
                _seekBy(-10);
                _showControls();
              },
              onForward10: () {
                _seekBy(10);
                _showControls();
              },
              // Previous and Next show for an episode or a queue, as on the PC: Previous goes back to the start after 3
              // seconds, and to the episode before near the start.
              showSteps: playback.inList || playback.previousEpisode != null || playback.nextEpisode != null,
              onPrevious: () => unawaited(playback.previous()),
              onNext: playback.nextEpisode == null ? null : () => unawaited(playback.next()),
              audio: _audioChip,
              subtitles: _subtitleChip,
              quality: _qualityChip,
              openMenu: _menu,
              onChip: _openMenu,
              chipKeys: _chipKeys,
              loop: playback.loopMode,
              onLoop: () {
                _cycleLoop();
                _showControls();
              },
              // A film outside any queue has nothing to shuffle.
              shuffle: playback.canShuffle && playback.inList ? playback.shuffle : null,
              onShuffle: _toggleShuffle,
              onUpNext: playback.link.features.contains('queues') ? () => _options(PlayerOptionsTab.upNext) : null,
            );

      // The open chip's menu sits above the dock, starting where its chip starts.
      Widget? menu;
      if (_menu case final open?) {
        final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
        final chip = _chipKeys[open]!.currentContext?.findRenderObject() as RenderBox?;
        final dockBox = _dockKey.currentContext?.findRenderObject() as RenderBox?;
        if (stack != null && chip != null && dockBox != null && stack.hasSize && chip.hasSize && dockBox.hasSize) {
          final width = (size.width - 24 - safe.left - safe.right).clamp(200.0, 300.0);
          final chipLeft = chip.localToGlobal(Offset.zero, ancestor: stack).dx;
          final dockTop = dockBox.localToGlobal(Offset.zero, ancestor: stack).dy;
          final left = chipLeft.clamp(safe.left + 12, size.width - safe.right - 12 - width);
          menu = Positioned(left: left, width: width, bottom: size.height - dockTop + 8, child: _menuCard(open, (dockTop - safe.top - 20).clamp(120.0, 480.0)));
        }
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _placeSubtitles(shown);
      });

      return Stack(
        key: _stackKey,
        fit: StackFit.expand,
        children: [
          Video(key: _videoKey, controller: controller!, controls: NoVideoControls, fill: Colors.black),
          // Taps anywhere on the picture show or hide the controls; double taps on a side seek.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _tapped,
              onDoubleTapDown: (details) => _doubleTapX = details.localPosition.dx,
              onDoubleTap: _doubleTapped,
            ),
          ),
          if (player != null)
            IgnorePointer(
              child: StreamBuilder<bool>(
                stream: player.stream.buffering,
                initialData: player.state.buffering,
                builder: (context, buffering) => buffering.data == true && pending == null
                    ? const Center(
                        child: SizedBox(width: 36, height: 36, child: CircularProgressIndicator(color: Palette.accent, strokeWidth: 2.5)),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          if (_rippleSeconds != 0) _SeekRipple(seconds: _rippleSeconds),
          IgnorePointer(
            ignoring: !shown,
            child: AnimatedOpacity(
              opacity: shown ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: Stack(
                children: [
                  // A menu dims the picture, and a tap on it closes the menu.
                  if (_menu != null)
                    Positioned.fill(
                      child: GestureDetector(
                        onTap: _closeMenu,
                        child: const ColoredBox(color: Color(0x52000000)),
                      ),
                    ),
                  AnimatedOpacity(
                    opacity: _menu == null ? 1 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: IgnorePointer(
                      ignoring: _menu != null,
                      child: Stack(
                        children: [
                          const Positioned(
                            left: 0,
                            right: 0,
                            top: 0,
                            height: 130,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [Color(0x9E000000), Color(0x00000000)],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Positioned(top: safe.top + 14, left: safe.left + side, right: safe.right + side, child: topBar),
                        ],
                      ),
                    ),
                  ),
                  // Above the gesture strip along the bottom edge, where a drag would go home instead of seeking.
                  Positioned(
                    left: safe.left + side,
                    right: safe.right + side,
                    bottom: safe.bottom + 14,
                    child: KeyedSubtree(key: _dockKey, child: dock),
                  ),
                  ?menu,
                ],
              ),
            ),
          ),
          if (pending?.episode != null)
            Positioned(
              top: safe.top + 72,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(child: _PendingChip(text: pending!.label)),
              ),
            ),
        ],
      );
    }

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        // The video waits while the screen slides away.
        if (didPop) unawaited(_player?.pause());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: switch (playback.phase) {
          // The small window shows the picture alone; its own buttons replace the controls.
          _ when inPip && controller != null => Video(key: ObjectKey(controller), controller: controller, controls: NoVideoControls, fill: Colors.black),
          PhonePlaybackPhase.failed => _Problem(message: playback.error ?? "The video didn't open.", onBack: _leave),
          _ when controller == null || player == null => _Opening(title: title, onBack: _leave),
          _ => body(),
        },
      ),
    );
  }
}

/// The timeline, following the player's position, length and buffer.
class _LiveTimeline extends StatelessWidget {
  const _LiveTimeline({required this.player, required this.portrait, required this.onSeek, required this.onDragging});
  final Player player;
  final bool portrait;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<bool> onDragging;

  @override
  Widget build(BuildContext context) => StreamBuilder<Duration>(
    stream: player.stream.duration,
    initialData: player.state.duration,
    builder: (context, duration) => StreamBuilder<Duration>(
      stream: player.stream.buffer,
      initialData: player.state.buffer,
      builder: (context, buffer) => StreamBuilder<Duration>(
        stream: player.stream.position,
        initialData: player.state.position,
        builder: (context, position) => DockTimeline(
          portrait: portrait,
          position: position.data ?? Duration.zero,
          duration: duration.data ?? Duration.zero,
          buffered: buffer.data ?? Duration.zero,
          onSeek: onSeek,
          onDragging: onDragging,
        ),
      ),
    ),
  );
}

/// The up-next dock, counting down, as on the PC.
class _UpNextLive extends StatefulWidget {
  const _UpNextLive({required this.offer, required this.portrait, required this.timeline, required this.onPlay, required this.onCancel});
  final UpNextOffer offer;
  final bool portrait;
  final Widget timeline;
  final VoidCallback onPlay;
  final VoidCallback onCancel;

  @override
  State<_UpNextLive> createState() => _UpNextLiveState();
}

class _UpNextLiveState extends State<_UpNextLive> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final offer = widget.offer;
    final left = offer.deadline.difference(DateTime.now());
    return UpNextDock(
      title: offer.step.title,
      detail: offer.step.detail,
      secondsLeft: (left.inMilliseconds / 1000).ceil().clamp(0, 999),
      progress: (1 - left.inMilliseconds / offer.length.inMilliseconds).clamp(0.0, 1.0),
      timeline: widget.timeline,
      onPlay: widget.onPlay,
      onCancel: widget.onCancel,
      portrait: widget.portrait,
    );
  }
}

/// How far a double tap seeked, over the side it was tapped on.
class _SeekRipple extends StatelessWidget {
  const _SeekRipple({required this.seconds});
  final int seconds;

  @override
  Widget build(BuildContext context) {
    final forward = seconds > 0;
    return IgnorePointer(
      child: Align(
        alignment: forward ? Alignment.centerRight : Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: 0.42,
          heightFactor: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0x1AFFFFFF),
              borderRadius: forward
                  ? const BorderRadius.horizontal(left: Radius.elliptical(400, 600))
                  : const BorderRadius.horizontal(right: Radius.elliptical(400, 600)),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(forward ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded, color: Colors.white, size: 30),
                  const SizedBox(height: 4),
                  Text(
                    '${forward ? '+' : '−'}${seconds.abs()} s',
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What the player waits on, over the picture: the next episode.
class _PendingChip extends StatelessWidget {
  const _PendingChip({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const ShapeDecoration(color: Color(0xE6151A17), shape: StadiumBorder()),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Palette.accent)),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Palette.ink, fontSize: 13.5, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    ),
  );
}

class _Opening extends StatelessWidget {
  const _Opening({required this.title, required this.onBack});
  final String title;
  final VoidCallback onBack;
  @override
  Widget build(BuildContext context) => SafeArea(
    child: Stack(
      children: [
        Positioned(
          left: 4,
          top: 4,
          child: IconButton(
            tooltip: 'Back',
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          ),
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Palette.accent, strokeWidth: 2.5),
              const SizedBox(height: 16),
              Text(title, style: const TextStyle(color: Colors.white, fontSize: 15)),
              const SizedBox(height: 4),
              const Text('Getting the video from the PC', style: TextStyle(color: Color(0x99FFFFFF), fontSize: 13)),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Problem extends StatelessWidget {
  const _Problem({required this.message, required this.onBack});
  final String message;
  final VoidCallback onBack;
  @override
  Widget build(BuildContext context) => SafeArea(
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, color: Palette.danger, size: 34),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.35),
            ),
            const SizedBox(height: 18),
            PebbleButton(label: 'Back', onTap: onBack),
          ],
        ),
      ),
    ),
  );
}

/// How far the player's controls keep from the screen's edges: clear of the camera cutout and of the gesture strip.
/// With the system bars hidden, Android reports neither in the padding, so the cutout comes from [cutout] (asked of
/// Android) or the display features, and the strip from the gesture insets.
@visibleForTesting
EdgeInsets controlInsets(MediaQueryData view, {EdgeInsets cutout = EdgeInsets.zero}) {
  final reported = cutout;
  double most(Iterable<double> values) => values.fold(0, (a, b) => a > b ? a : b);
  cutout = EdgeInsets.zero;
  final size = view.size;
  for (final feature in view.displayFeatures.where((f) => f.type == DisplayFeatureType.cutout)) {
    final b = feature.bounds;
    // The cutout belongs to the edge it is nearest; the controls stay past its far side.
    final distances = {'top': b.top, 'bottom': size.height - b.bottom, 'left': b.left, 'right': size.width - b.right};
    final edge = distances.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
    cutout = switch (edge) {
      'top' => cutout.copyWith(top: most([cutout.top, b.bottom])),
      'bottom' => cutout.copyWith(bottom: most([cutout.bottom, size.height - b.top])),
      'left' => cutout.copyWith(left: most([cutout.left, b.right])),
      _ => cutout.copyWith(right: most([cutout.right, size.width - b.left])),
    };
  }
  return EdgeInsets.fromLTRB(
    most([view.viewPadding.left, view.padding.left, cutout.left, reported.left]),
    most([view.viewPadding.top, view.padding.top, cutout.top, reported.top]),
    most([view.viewPadding.right, view.padding.right, cutout.right, reported.right]),
    most([view.viewPadding.bottom, view.padding.bottom, view.systemGestureInsets.bottom, cutout.bottom, reported.bottom]),
  );
}
