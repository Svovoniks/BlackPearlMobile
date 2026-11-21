import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../connection/remote_link.dart';
import '../connection/transport.dart';
import '../protocol/remote_state.dart';
import 'pebbles.dart';
import 'theme.dart';

/// The Remote tab: what's playing on the PC and everything the player's bars do.
class RemoteScreen extends StatefulWidget {
  const RemoteScreen({super.key, required this.link, required this.onChoosePc, required this.onPairAgain, this.onWatchHere});

  final RemoteLink link;

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
  Timer? _volumeTimer;
  int? _volumeOverride;
  DateTime _volumeChangedAt = DateTime.fromMillisecondsSinceEpoch(0);
  int? _sentVolume;
  int? _seekTarget;
  DateTime? _seekAt;
  double? _dragFraction;
  String? _feedback;
  Timer? _feedbackTimer;

  RemoteLink get link => widget.link;

  @override
  void initState() {
    super.initState();
    link.addListener(_changed);
    link.notice.addListener(_showNotice);
    _syncTicker();
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
    }
  }

  @override
  void dispose() {
    link.removeListener(_changed);
    link.notice.removeListener(_showNotice);
    _ticker?.cancel();
    _volumeTimer?.cancel();
    _feedbackTimer?.cancel();
    super.dispose();
  }

  void _changed() {
    final at = link.stateReceivedAt;
    // A state that arrived after the seek replaces the guess.
    if (_seekAt != null && at != null && at.isAfter(_seekAt!)) {
      _seekTarget = null;
      _seekAt = null;
    }
    if (_volumeOverride != null && DateTime.now().difference(_volumeChangedAt) > const Duration(milliseconds: 1500)) {
      _volumeOverride = null;
    }
    _syncTicker();
    setState(() {});
  }

  void _syncTicker() {
    final playing = link.state?.playing == true && link.status.isConnected;
    if (playing && _ticker == null) {
      _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (mounted) setState(() {});
      });
    } else if (!playing) {
      _ticker?.cancel();
      _ticker = null;
    }
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

  int get _position {
    if (_dragFraction != null) return (_dragFraction! * (_state?.durationMs ?? 0)).round();
    if (_seekTarget != null && _seekAt != null) {
      final elapsed = _state?.playing == true ? DateTime.now().difference(_seekAt!).inMilliseconds : 0;
      final duration = _state?.durationMs ?? 0;
      final position = _seekTarget! + elapsed;
      return duration > 0 ? math.min(position, duration) : position;
    }
    return link.currentPositionMs();
  }

  int get _volume => _volumeOverride ?? _state?.volume ?? 0;

  void _seekBy(int ms) {
    if (!_canPlay) return;
    // The guess is made before sending: a state that answers the command must replace it, not add to it.
    final duration = _state?.durationMs ?? 0;
    _seekTarget = (_position + ms).clamp(0, duration > 0 ? duration : 1 << 40);
    _seekAt = DateTime.now();
    link.command('seek-by', ms);
    _flash(ms > 0 ? '+${ms ~/ 1000} s' : '−${-ms ~/ 1000} s');
  }

  void _seekTo(double fraction) {
    final duration = _state?.durationMs ?? 0;
    if (!_canPlay || duration <= 0) return;
    final target = (fraction.clamp(0.0, 1.0) * duration).round();
    _seekTarget = target;
    _seekAt = DateTime.now();
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
    setState(() {
      _volumeOverride = clamped;
      _volumeChangedAt = DateTime.now();
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
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
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
    final children = <Widget>[
      if (!status.isConnected) ...[_ConnectionBanner(link: link, onPairAgain: widget.onPairAgain), const SizedBox(height: 12)],
      if (!state.media) ...[_Nothing(pcName: link.pcName, connected: status.isConnected)] else ..._playing(state),
    ];
    // The touch pad takes whatever height the controls leave. On a screen too short for its smallest size, it all
    // scrolls instead of squeezing.
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          sliver: SliverFillRemaining(
            hasScrollBody: false,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
        ),
      ],
    );
  }

  List<Widget> _playing(RemoteState state) {
    final duration = state.durationMs;
    final position = _position;
    final fraction = duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0;
    return [
      Expanded(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 116),
          child: _TouchPad(
            enabled: _canPlay,
            volumeEnabled: _canAdjust,
            feedback: _feedback,
            onTap: _toggle,
            onSwipe: (forward) => _seekBy(forward ? 10000 : -10000),
            volume: () => _volume,
            onVolume: (value, done) {
              _setVolume(value, done: done);
              _flash('Volume $value%');
            },
          ),
        ),
      ),
      const SizedBox(height: 16),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(state.title.isEmpty ? 'Untitled' : state.title, style: display(26), maxLines: 2, overflow: TextOverflow.ellipsis),
                if (state.detail.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    state.detail,
                    style: const TextStyle(color: Palette.muted, fontSize: 14),
                    maxLines: 2,
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
      const SizedBox(height: 16),
      _Timeline(
        fraction: _dragFraction ?? fraction,
        enabled: _canPlay && duration > 0,
        onDrag: (value) => setState(() => _dragFraction = value),
        onRelease: (value) {
          _seekTo(value);
          setState(() => _dragFraction = null);
        },
      ),
      const SizedBox(height: 2),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            formatClock(position),
            style: const TextStyle(color: Palette.muted, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]),
          ),
          Text(
            duration > 0 ? '−${formatClock(duration - position)}' : '',
            style: const TextStyle(color: Palette.muted, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]),
          ),
        ],
      ),
      if (!state.canControl && _connected) ...[const SizedBox(height: 12), _CantControl(room: state.room)],
      const SizedBox(height: 14),
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
      Row(
        children: [
          Expanded(
            child: _Pill(label: 'Stop', icon: Icons.stop_rounded, enabled: _canPlay, onTap: () => link.command('stop')),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _Pill(
              label: 'Loop',
              value: state.loop.label,
              icon: state.loop == LoopMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
              active: state.loop != LoopMode.off,
              enabled: _canPlay,
              onTap: () => link.command('loop'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _Pill(
              label: 'Fullscreen',
              value: state.fullscreen ? 'On' : 'Off',
              icon: state.fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
              active: state.fullscreen,
              enabled: _canAdjust,
              onTap: () => link.command('fullscreen'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Pebble(
            width: 44,
            height: 44,
            enabled: _canAdjust,
            onTap: () => link.command('mute'),
            semanticLabel: state.muted ? 'Unmute' : 'Mute',
            child: Icon(
              state.muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              size: 21,
              color: state.muted ? Palette.danger : null,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: _VolumeTrack(
              value: _volume,
              muted: state.muted,
              enabled: _canAdjust,
              onChanged: (value) => _setVolume(value),
              onChangeEnd: (value) => _setVolume(value, done: true),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 42,
            child: Text(
              state.muted ? 'Muted' : '$_volume%',
              textAlign: TextAlign.right,
              style: const TextStyle(color: Palette.muted, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
        ],
      ),
    ];
  }
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
    return Slab(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
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
              padding: const EdgeInsets.symmetric(horizontal: 14),
              onTap: onPairAgain,
              child: const Text('Pair', style: TextStyle(fontSize: 13)),
            )
          else if (status.phase == LinkPhase.failed || status.phase == LinkPhase.waitingForPc)
            Pebble(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              onTap: link.retryNow,
              child: const Text('Retry', style: TextStyle(fontSize: 13)),
            ),
        ],
      ),
    );
  }
}

class StatusCopy {
  const StatusCopy(this.headline, this.detail, this.icon, {this.shortDetail});
  final String headline;
  final String detail;
  final String? shortDetail;
  final IconData icon;
}

/// The words for each connection state.
StatusCopy describe(LinkStatus status, String pcName) => switch (status.phase) {
  LinkPhase.connecting => StatusCopy(
    'Connecting…',
    'Reaching the room server that introduces this phone to $pcName.',
    Icons.cloud_outlined,
  ),
  LinkPhase.linking => StatusCopy('Reaching $pcName…', 'Setting up a direct, encrypted link to the PC.', Icons.link_rounded),
  LinkPhase.pairing => StatusCopy('Pairing with $pcName…', 'The PC is adding this phone.', Icons.link_rounded),
  LinkPhase.waitingForPc => StatusCopy(
    "Your PC isn't online",
    'Open BlackPearl on $pcName and turn on Phone remote in Settings › Profile. This connects as soon as the PC is back.',
    Icons.desktop_access_disabled_outlined,
    shortDetail: 'Connects as soon as the PC is back.',
  ),
  LinkPhase.failed => StatusCopy(
    status.message ?? "Couldn't connect",
    status.needsPairing ? 'Show a new pairing code on the PC and scan it.' : '',
    status.needsPairing ? Icons.link_off_rounded : Icons.error_outline_rounded,
  ),
  LinkPhase.idle => StatusCopy('Not connected', 'The remote reconnects when you come back to the app.', Icons.pause_circle_outline_rounded),
  LinkPhase.connected => StatusCopy('Connected', '', Icons.check_circle_outline_rounded),
};

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

class _Nothing extends StatelessWidget {
  const _Nothing({required this.pcName, required this.connected});
  final String pcName;
  final bool connected;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 40),
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
          connected ? 'Start a video on $pcName and its controls appear here.' : 'When $pcName plays something, its controls appear here.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Palette.muted, fontSize: 14.5, height: 1.4),
        ),
      ],
    ),
  );
}

/// Label with a small value under it, as the mockup's pills.
class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.icon, this.value, this.active = false, required this.enabled, required this.onTap});
  final String label;
  final String? value;
  final IconData icon;
  final bool active;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pebble(
    height: 54,
    radius: 18,
    enabled: enabled,
    onTap: onTap,
    semanticLabel: value == null ? label : '$label, $value',
    padding: const EdgeInsets.symmetric(horizontal: 10),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 20, color: active ? Palette.accent : null),
        const SizedBox(width: 7),
        Flexible(
          // Narrow phones shrink the words a little rather than cutting them off.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, maxLines: 1, style: const TextStyle(fontSize: 13, height: 1.15)),
                if (value != null)
                  Text(
                    value!,
                    maxLines: 1,
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
        ),
      ],
    ),
  );
}

/// The timeline: a well with an accent fill and a knob. Tap or drag; the seek is sent on release.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.fraction, required this.enabled, required this.onDrag, required this.onRelease});
  final double fraction;
  final bool enabled;
  final ValueChanged<double> onDrag;
  final ValueChanged<double> onRelease;

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
        onTapUp: enabled ? (d) => onRelease(at(d.localPosition)) : null,
        child: SizedBox(
          height: 30,
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
  const _VolumeTrack({required this.value, required this.muted, required this.enabled, required this.onChanged, required this.onChangeEnd});
  final int value;
  final bool muted;
  final bool enabled;
  final ValueChanged<int> onChanged;
  final ValueChanged<int> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    int at(Offset local) => ((local.dx / math.max(1.0, context.size?.width ?? 1)).clamp(0.0, 1.0) * 100).round();
    return Semantics(
      slider: true,
      enabled: enabled,
      label: 'PC volume',
      value: '$value%',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: enabled ? (d) => onChanged(at(d.localPosition)) : null,
        onHorizontalDragUpdate: enabled ? (d) => onChanged(at(d.localPosition)) : null,
        onHorizontalDragEnd: enabled ? (d) => onChangeEnd(at(d.localPosition)) : null,
        onTapUp: enabled ? (d) => onChangeEnd(at(d.localPosition)) : null,
        child: SizedBox(
          height: 36,
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
