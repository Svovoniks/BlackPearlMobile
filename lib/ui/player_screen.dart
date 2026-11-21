import 'dart:async';
import 'dart:ui' show DisplayFeatureType;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../playback/phone_playback.dart';
import '../playback/picture_in_picture.dart';
import '../storage/app_settings.dart';
import 'pebbles.dart';
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
    unawaited(pip.refresh().then((_) {
      if (mounted) {
        _syncPip();
        setState(() {});
      }
    }));
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
    _handingNow.dispose();
    _loop.dispose();
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
      for (final subscription in _playerSubscriptions) {
        unawaited(subscription.cancel());
      }
      _playerSubscriptions.clear();
      if (player != null) {
        void sync(Object? _) => _syncPip();
        _playerSubscriptions
          ..add(player.stream.playing.listen(sync))
          ..add(player.stream.width.listen(sync))
          ..add(player.stream.height.listen(sync));
      }
      _syncPip();
    }
    final note = playback.stream?.note;
    if (note != null && note != _noteShown) {
      _noteShown = note;
      WidgetsBinding.instance.addPostFrameCallback((_) => _say(note));
    }
    if (mounted) setState(() {});
  }

  // What the bars show that changes while they are on screen. media_kit_video hands its controls a new theme only
  // with a new key, which also hides them, so these buttons listen for themselves.
  final ValueNotifier<bool> _handingNow = ValueNotifier(false);
  late final ValueNotifier<String> _loop = ValueNotifier(playback.loopMode);

  void _pipChanged() {
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
    unawaited(pip.update(
      wanted: state?.playing ?? false,
      width: (state?.width ?? 0) > 0 ? state!.width! : 16,
      height: (state?.height ?? 0) > 0 ? state!.height! : 9,
      playing: state?.playing ?? false,
    ));
  }

  void _notice() {
    final text = playback.notice.value;
    if (text != null) _say(text);
  }

  void _say(String text, {Duration duration = const Duration(seconds: 6)}) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: duration));
  }

  // Leaving pops the screen; whoever opened it then stops the phone's player, once its picture is off screen.
  void _leave() => Navigator.of(context).pop();

  Future<void> _continueOnPc() async {
    if (_handing) return;
    _handing = _handingNow.value = true;
    final error = await playback.continueOnPc();
    if (!mounted) return;
    _handing = _handingNow.value = false;
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
    playback.loopMode = _loop.value = next;
    unawaited(widget.settings?.setLoopMode(next));
    _say(switch (next) {
      'all' => playback.stream?.next != null || playback.stream?.first != null
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

  @override
  Widget build(BuildContext context) {
    final stream = playback.stream;
    final controller = _controller;
    final title = stream?.title ?? 'Opening…';
    final narrow = MediaQuery.sizeOf(context).width < 600;
    const white = Colors.white;
    Widget live(Widget Function(BuildContext context) builder, [List<Listenable> also = const []]) =>
        ListenableBuilder(listenable: Listenable.merge([playback, ...also]), builder: (context, _) => builder(context));
    final top = <Widget>[
      IconButton(tooltip: 'Back', onPressed: _leave, icon: const Icon(Icons.arrow_back_rounded, color: white)),
      Expanded(
        child: live((context) {
          final stream = playback.stream;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(stream?.title ?? 'Opening…', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: white, fontSize: 16, fontWeight: FontWeight.w600)),
              if (stream?.detail != null)
                Text(stream!.detail!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 12.5)),
            ],
          );
        }),
      ),
      if (pip.supported)
        IconButton(tooltip: 'Picture in picture', onPressed: () => unawaited(pip.enter()), icon: const Icon(Icons.picture_in_picture_alt_rounded, color: white)),
      IconButton(tooltip: 'Audio, subtitles and quality', onPressed: _options, icon: const Icon(Icons.tune_rounded, color: white)),
      Padding(
        padding: const EdgeInsets.only(left: 4, right: 4),
        child: live((context) {
          final handing = _handingNow.value;
          return Tooltip(
            message: 'Continue on ${widget.pcName}',
            child: Pebble(
              height: 38,
              width: narrow ? 38 : null,
              enabled: !handing && playback.stream != null,
              onTap: _continueOnPc,
              semanticLabel: 'Continue on ${widget.pcName}',
              padding: narrow ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 14),
              // In portrait the title needs the room; the button keeps its place as an icon.
              child: narrow
                  ? (handing
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Palette.ink))
                        : const Icon(Icons.desktop_windows_outlined, size: 18))
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.desktop_windows_outlined, size: 17),
                        const SizedBox(width: 7),
                        Text(handing ? 'Starting…' : 'Continue on PC', style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                      ],
                    ),
            ),
          );
        }, [_handingNow]),
      ),
    ];
    Widget round(IconData icon, String tooltip, VoidCallback? onPressed, {double size = 30}) => IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: size,
      color: white,
      disabledColor: const Color(0x55FFFFFF),
      icon: Icon(icon),
    );
    // Previous and Next show for an episode, as on the PC: Previous goes back to the start after 3 seconds, and to the
    // episode before near the start.
    Widget step(bool forward) => live((context) {
      final stream = playback.stream;
      if (stream?.previous == null && stream?.next == null) return const SizedBox.shrink();
      return forward
          ? round(Icons.skip_next_rounded, 'Next episode', stream?.next == null ? null : () => unawaited(playback.next()))
          : round(Icons.skip_previous_rounded, 'Previous', () => unawaited(playback.previous()));
    });
    final primary = <Widget>[
      step(false),
      round(Icons.replay_10_rounded, 'Back 10 seconds', () => _seekBy(-10)),
      const SizedBox(width: 6),
      const MaterialPlayOrPauseButton(iconSize: 52),
      const SizedBox(width: 6),
      round(Icons.forward_10_rounded, 'Forward 10 seconds', () => _seekBy(10)),
      step(true),
    ];
    final bottom = <Widget>[
      const MaterialPositionIndicator(),
      const Spacer(),
      ValueListenableBuilder<String>(
        valueListenable: _loop,
        builder: (context, loop, _) => IconButton(
          tooltip: switch (loop) {
            'all' => 'Loop all',
            'one' => 'Loop one',
            _ => 'Loop off',
          },
          onPressed: _cycleLoop,
          icon: Icon(loop == 'one' ? Icons.repeat_one_rounded : Icons.repeat_rounded, color: loop == 'off' ? const Color(0x99FFFFFF) : Palette.accent),
        ),
      ),
      IconButton(
        tooltip: 'Subtitles',
        onPressed: () => _options(PlayerOptionsTab.subtitles),
        icon: const Icon(Icons.subtitles_outlined, color: white),
      ),
    ];
    // The controls keep clear of the camera cutout and the rounded corners; the picture may go under them.
    final safe = controlInsets(MediaQuery.of(context), cutout: _cutout);
    final theme = MaterialVideoControlsThemeData(
      padding: safe.copyWith(bottom: 0),
      topButtonBar: top,
      topButtonBarMargin: const EdgeInsets.fromLTRB(4, 8, 8, 0),
      primaryButtonBar: primary,
      seekBarPositionColor: Palette.accent,
      // Above the gesture strip along the bottom edge, where a drag would go home instead of seeking.
      seekBarMargin: EdgeInsets.fromLTRB(16, 0, 16, 18 + safe.bottom),
      bottomButtonBarMargin: EdgeInsets.fromLTRB(16, 0, 8, 26 + safe.bottom),
      seekBarThumbColor: Palette.knob,
      seekBarBufferColor: const Color(0x66FFFFFF),
      seekOnDoubleTap: true,
      // Subtitles move up while the controls show, rather than sit on the timeline.
      shiftSubtitlesOnControlsVisibilityChange: true,
      volumeGesture: false,
      brightnessGesture: false,
      bottomButtonBar: bottom,
      bufferingIndicatorBuilder: (_) => const CircularProgressIndicator(color: Palette.accent, strokeWidth: 2.5),
    );
    final inPip = pip.active.value;
    final pending = playback.pending.value;
    final upNext = playback.upNext.value;
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
          _ when controller == null => _Opening(title: title, onBack: _leave),
          _ => Stack(
            fit: StackFit.expand,
            children: [
              // media_kit_video 2.0.1 tells its controls about a new theme only when it is the same one
              // (updateShouldNotify is inverted), so new insets or buttons need new controls.
              MaterialVideoControlsTheme(
                key: ValueKey((safe, narrow)),
                normal: theme,
                fullscreen: theme,
                child: Video(key: ObjectKey(controller), controller: controller, controls: MaterialVideoControls, fill: Colors.black),
              ),
              if (pending != null)
                Positioned(
                  top: safe.top + 64,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(child: Center(child: _PendingChip(text: pending.label))),
                ),
              if (upNext != null)
                // Clear of the buttons in the middle: across the bottom in portrait, at the bottom left in landscape.
                Positioned(
                  left: 16 + safe.left,
                  right: narrow ? 16 + safe.right : null,
                  bottom: 96 + safe.bottom,
                  child: _UpNextCard(
                    // In landscape it stays left of the buttons in the middle, about 300 wide with Previous and Next.
                    maxWidth: narrow ? 340 : ((MediaQuery.sizeOf(context).width - 300) / 2 - 24 - safe.left).clamp(230.0, 340.0),
                    offer: upNext,
                    onPlay: () => unawaited(playback.playUpNext()),
                    onCancel: playback.cancelUpNext,
                  ),
                ),
            ],
          ),
        },
      ),
    );
  }
}

/// What the player waits on, over the picture: another quality or the next episode.
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
          Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Palette.ink, fontSize: 13.5, fontWeight: FontWeight.w500))),
        ],
      ),
    ),
  );
}

/// The next episode, with a countdown, as on the PC: it plays when the bar fills, unless canceled.
class _UpNextCard extends StatefulWidget {
  const _UpNextCard({required this.offer, required this.onPlay, required this.onCancel, this.maxWidth = 340});
  final UpNextOffer offer;
  final double maxWidth;
  final VoidCallback onPlay;
  final VoidCallback onCancel;

  @override
  State<_UpNextCard> createState() => _UpNextCardState();
}

class _UpNextCardState extends State<_UpNextCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
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
    final seconds = (left.inMilliseconds / 1000).ceil().clamp(0, 999);
    final progress = (1 - left.inMilliseconds / offer.length.inMilliseconds).clamp(0.0, 1.0);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: widget.maxWidth),
      child: Material(
        color: const Color(0xF2151A17),
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Up next · playing in ${seconds}s', style: const TextStyle(color: Palette.muted, fontSize: 12)),
                  const SizedBox(height: 3),
                  Text(offer.step.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Palette.ink, fontSize: 15, fontWeight: FontWeight.w600)),
                  if (offer.step.detail != null)
                    Text(offer.step.detail!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Palette.muted, fontSize: 12.5)),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: widget.onCancel,
                        style: TextButton.styleFrom(foregroundColor: Palette.ink),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 6),
                      Pebble(
                        lit: true,
                        height: 36,
                        onTap: widget.onPlay,
                        semanticLabel: 'Play now',
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.play_arrow_rounded, size: 18),
                            SizedBox(width: 4),
                            Text('Play now', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            LinearProgressIndicator(value: progress, minHeight: 3, color: Palette.accent, backgroundColor: const Color(0x26FFFFFF)),
          ],
        ),
      ),
    );
  }
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
          child: IconButton(tooltip: 'Back', onPressed: onBack, icon: const Icon(Icons.arrow_back_rounded, color: Colors.white)),
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
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.35)),
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
