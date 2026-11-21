import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../playback/phone_playback.dart';
import '../protocol/library.dart';
import 'pebbles.dart';
import 'theme.dart';

/// The phone's own player, full screen. Leaving it stops the video here and saves where it got to on the PC.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.playback, required this.pcName, this.onHandedToPc});
  final PhonePlayback playback;
  final String pcName;

  /// The PC took the video over; the app shows the Remote.
  final VoidCallback? onHandedToPc;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  VideoController? _controller;
  Player? _player;
  String? _noteShown;
  bool _handing = false;

  PhonePlayback get playback => widget.playback;

  @override
  void initState() {
    super.initState();
    playback.addListener(_changed);
    playback.notice.addListener(_notice);
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    _changed();
  }

  @override
  void dispose() {
    playback.removeListener(_changed);
    playback.notice.removeListener(_notice);
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    unawaited(SystemChrome.setPreferredOrientations([]));
    super.dispose();
  }

  void _changed() {
    final player = playback.player;
    if (!identical(player, _player)) {
      _player = player;
      _controller = player == null ? null : VideoController(player);
    }
    final note = playback.stream?.note;
    if (note != null && note != _noteShown) {
      _noteShown = note;
      WidgetsBinding.instance.addPostFrameCallback((_) => _say(note));
    }
    if (mounted) setState(() {});
  }

  void _notice() {
    final text = playback.notice.value;
    if (text != null) _say(text);
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 6)));
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

  Future<void> _options() async {
    final player = _player;
    final stream = playback.stream;
    if (player == null || stream == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _PlayerOptions(player: player, stream: stream, onQuality: (quality) => unawaited(playback.changeQuality(quality))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final stream = playback.stream;
    final controller = _controller;
    final title = stream?.title ?? 'Opening…';
    final top = <Widget>[
      IconButton(tooltip: 'Back', onPressed: _leave, icon: const Icon(Icons.arrow_back_rounded, color: Colors.white)),
      Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
            if (stream?.detail != null)
              Text(stream!.detail!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 12.5)),
          ],
        ),
      ),
      IconButton(tooltip: 'Audio, subtitles and quality', onPressed: _options, icon: const Icon(Icons.tune_rounded, color: Colors.white)),
      Padding(
        padding: const EdgeInsets.only(left: 4, right: 4),
        child: Pebble(
          height: 38,
          enabled: !_handing && stream != null,
          onTap: _continueOnPc,
          semanticLabel: 'Continue on ${widget.pcName}',
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.desktop_windows_outlined, size: 17),
              const SizedBox(width: 7),
              Text(_handing ? 'Starting…' : 'Continue on PC', style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    ];
    final theme = MaterialVideoControlsThemeData(
      topButtonBar: top,
      topButtonBarMargin: const EdgeInsets.fromLTRB(4, 8, 8, 0),
      seekBarPositionColor: Palette.accent,
      seekBarMargin: const EdgeInsets.fromLTRB(16, 0, 16, 18),
      bottomButtonBarMargin: const EdgeInsets.fromLTRB(16, 0, 16, 26),
      seekBarThumbColor: Palette.knob,
      seekBarBufferColor: const Color(0x66FFFFFF),
      seekOnDoubleTap: true,
      volumeGesture: false,
      brightnessGesture: false,
      bottomButtonBar: const [MaterialPositionIndicator(), Spacer()],
      bufferingIndicatorBuilder: (_) => const CircularProgressIndicator(color: Palette.accent, strokeWidth: 2.5),
    );
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        // The video waits while the screen slides away.
        if (didPop) unawaited(_player?.pause());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: switch (playback.phase) {
          PhonePlaybackPhase.failed => _Problem(message: playback.error ?? "The video didn't open.", onBack: _leave),
          _ when controller == null => _Opening(title: title, onBack: _leave),
          _ => MaterialVideoControlsTheme(
            normal: theme,
            fullscreen: theme,
            // A new player (another quality) needs a new surface; the widget doesn't swap one by itself.
            child: Video(key: ObjectKey(controller), controller: controller, controls: MaterialVideoControls, fill: Colors.black),
          ),
        },
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

/// Audio, subtitles, and the stream's quality.
class _PlayerOptions extends StatefulWidget {
  const _PlayerOptions({required this.player, required this.stream, required this.onQuality});
  final Player player;
  final StreamInfo stream;
  final void Function(String quality) onQuality;
  @override
  State<_PlayerOptions> createState() => _PlayerOptionsState();
}

class _PlayerOptionsState extends State<_PlayerOptions> {
  final List<StreamSubscription<Object?>> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    // Tracks arrive once the video has opened, which can be after the sheet.
    void refresh(Object? _) {
      if (mounted) setState(() {});
    }

    _subscriptions
      ..add(widget.player.stream.tracks.listen(refresh))
      ..add(widget.player.stream.track.listen(refresh));
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.player.state;
    String name(String? title, String? language, String id) =>
        [if (title != null && title.isNotEmpty) title, if (language != null && language.isNotEmpty) language.toUpperCase()].join(' · ').ifEmpty('Track $id');
    final audio = state.tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
    final subtitles = state.tracks.subtitle.where((t) => t.id != 'auto').toList();
    Widget choice(String label, bool selected, VoidCallback onTap) => ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: const TextStyle(fontSize: 14.5)),
      trailing: selected ? const Icon(Icons.check_rounded, color: Palette.accent) : null,
      onTap: () {
        onTap();
        setState(() {});
      },
    );
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (audio.length > 1) ...[
              Text('Audio', style: display(18)),
              for (final track in audio) choice(name(track.title, track.language, track.id), state.track.audio.id == track.id, () => widget.player.setAudioTrack(track)),
              const SizedBox(height: 12),
            ],
            Text('Subtitles', style: display(18)),
            for (final track in subtitles)
              choice(track.id == 'no' ? 'Off' : name(track.title, track.language, track.id), state.track.subtitle.id == track.id, () => widget.player.setSubtitleTrack(track)),
            if (subtitles.length <= 1)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  widget.stream.hls ? 'A converted stream carries no subtitles. Choose Original file for them.' : 'This video has no subtitles.',
                  style: const TextStyle(color: Palette.muted),
                ),
              ),
            if (widget.stream.qualities.length > 1) ...[
              const SizedBox(height: 16),
              Text('Quality', style: display(18)),
              const Padding(
                padding: EdgeInsets.only(top: 2, bottom: 4),
                child: Text('A lower quality plays smoother on a slow connection. The PC converts it as you watch.', style: TextStyle(color: Palette.muted, fontSize: 12.5)),
              ),
              for (final quality in widget.stream.qualities)
                choice(qualityLabel(quality), widget.stream.quality == quality, () {
                  Navigator.of(context).pop();
                  if (quality != widget.stream.quality) widget.onQuality(quality);
                }),
            ],
          ],
        ),
      ),
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
