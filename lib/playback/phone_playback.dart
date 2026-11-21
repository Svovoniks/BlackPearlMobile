import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../connection/remote_link.dart';
import '../connection/transport.dart';
import '../protocol/library.dart';
import 'media_proxy.dart';

/// What the phone's player does: what it opened, and how it's going.
enum PhonePlaybackPhase { idle, opening, playing, failed }

/// Plays a PC's video on the phone (PHONE-REMOTE.md, "Watching on the phone"). The PC sends the video over the link;
/// [MediaProxy] hands it to libmpv. How far the phone gets goes back to the PC as `progress`, so Continue watching
/// and the watched marks are the same on both.
class PhonePlayback extends ChangeNotifier {
  PhonePlayback({required this.link, MediaProxy? proxy, Player Function()? createPlayer, this.awayQuality = 'auto'})
    : _createPlayer = createPlayer ?? _defaultPlayer {
    this.proxy = proxy ?? MediaProxy(reader: () => link.media);
  }

  final RemoteLink link;
  late final MediaProxy proxy;
  final Player Function() _createPlayer;

  /// The quality asked for away from home: `auto`, `original`, `1080p`, `720p` or `480p`.
  String awayQuality;

  static Player _defaultPlayer() {
    final player = Player(configuration: const PlayerConfiguration(bufferSize: 96 * 1024 * 1024, title: 'BlackPearl'));
    final native = player.platform;
    if (native is NativePlayer) {
      // The link can stall for a while when the phone changes networks; mpv waits for the proxy instead of giving up.
      unawaited(native.setProperty('network-timeout', '120').catchError((_) {}));
      unawaited(native.setProperty('cache', 'yes').catchError((_) {}));
      unawaited(native.setProperty('demuxer-readahead-secs', '60').catchError((_) {}));
    }
    return player;
  }

  Player? _player;
  Player? get player => _player;
  StreamInfo? _stream;
  StreamInfo? get stream => _stream;
  Uri? _address;
  PhonePlaybackPhase _phase = PhonePlaybackPhase.idle;
  PhonePlaybackPhase get phase => _phase;
  String? _error;
  String? get error => _error;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  Timer? _progressTimer;
  int _lastReported = -1;
  bool _ended = false;
  int _opening = 0;

  bool get active => _stream != null || _phase == PhonePlaybackPhase.opening;

  String get _network => switch (link.status.path) {
    NetworkPath.home => 'home',
    NetworkPath.relayed => 'relayed',
    _ => 'away',
  };

  /// Starts [id] on the phone. [takeOver]: it's the video the PC plays now; the PC stops and the phone continues from
  /// where it was. [quality] overrides the automatic choice; [startAt] the PC's resume point.
  Future<void> watch(String id, {bool takeOver = false, String? quality, int? startAt}) async {
    final attempt = ++_opening;
    await _report(final_: true);
    _phase = PhonePlaybackPhase.opening;
    _error = null;
    notifyListeners();
    final StreamInfo? info;
    try {
      final reply = await link.ask('watch', {
        'id': id,
        'quality': quality ?? (_network == 'home' ? 'auto' : awayQuality),
        'network': _network,
        'takeOver': takeOver,
      }, timeout: const Duration(seconds: 45));
      info = StreamInfo.fromJson(reply);
    } on RemoteRequestException catch (e) {
      if (attempt == _opening) _fail(e.message);
      return;
    }
    if (attempt != _opening) return;
    if (info == null) {
      _fail("The PC's answer didn't say how to play the video.");
      return;
    }
    await _closePlayer(stopStream: false);
    _stream = info;
    _ended = false;
    _lastReported = -1;
    final player = _player = _createPlayer();
    _listen(player);
    final address = _address = await proxy.open(info);
    final start = startAt ?? info.positionMs;
    await player.open(Media(address.toString(), start: start > 0 ? Duration(milliseconds: start) : null));
    if (attempt != _opening) return;
    _phase = PhonePlaybackPhase.playing;
    notifyListeners();
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_player?.state.playing == true) unawaited(_report());
    });
  }

  /// Opens the same video again at another quality, from where it is now.
  Future<void> changeQuality(String quality) async {
    final current = _stream;
    if (current == null) return;
    final position = _player?.state.position.inMilliseconds ?? current.positionMs;
    await watch(current.id, quality: quality, startAt: position);
  }

  void _listen(Player player) {
    _subscriptions.add(player.stream.playing.listen((playing) {
      // A pause is a natural moment to save where the phone is.
      if (!playing) unawaited(_report());
      notifyListeners();
    }));
    _subscriptions.add(player.stream.completed.listen((completed) {
      if (!completed || _stream == null) return;
      _ended = true;
      unawaited(_report(final_: true));
      notifyListeners();
    }));
    _subscriptions.add(player.stream.error.listen((message) {
      if (kDebugMode) debugPrint('player: $message');
    }));
  }

  /// Tells the PC how far the phone got. [final_]: the last report of this viewing.
  Future<void> _report({bool final_ = false}) async {
    final stream = _stream;
    final player = _player;
    if (stream == null || player == null) return;
    final position = player.state.position.inMilliseconds;
    var duration = player.state.duration.inMilliseconds;
    if (duration <= 0) duration = stream.durationMs;
    if (position <= 0 && !_ended) return;
    if (!final_ && !_ended && (position - _lastReported).abs() < 1000) return;
    _lastReported = position;
    link.tell('progress', {'id': stream.id, 'positionMs': position, 'durationMs': duration, 'ended': _ended, 'final': final_});
  }

  /// Continue on the PC: the phone stops here, and the PC plays the video from the same moment.
  Future<String?> continueOnPc() async {
    final stream = _stream;
    final player = _player;
    if (stream == null || player == null) return null;
    await player.pause();
    final position = player.state.position.inMilliseconds;
    await _report(final_: true);
    try {
      await link.ask('play', {'id': stream.id, 'positionMs': position}, timeout: const Duration(seconds: 30));
    } on RemoteRequestException catch (e) {
      return e.message;
    }
    await stop(reported: true);
    return null;
  }

  /// Stops playing on the phone, saving where it got to.
  Future<void> stop({bool reported = false}) async {
    _opening++;
    if (!reported) await _report(final_: true);
    await _closePlayer(stopStream: true);
    _phase = PhonePlaybackPhase.idle;
    _error = null;
    notifyListeners();
  }

  /// The app went to the background: the video waits, and the PC learns where it is.
  Future<void> background() async {
    final player = _player;
    if (player == null) return;
    if (player.state.playing) await player.pause();
    await _report(final_: true);
  }

  void _fail(String message) {
    _phase = PhonePlaybackPhase.failed;
    _error = message;
    notifyListeners();
  }

  Future<void> _closePlayer({required bool stopStream}) async {
    _progressTimer?.cancel();
    _progressTimer = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    final player = _player;
    _player = null;
    final address = _address;
    _address = null;
    if (address != null) proxy.close(address);
    if (stopStream && _stream != null) link.tell('stream-stop', {});
    _stream = null;
    if (player != null) {
      try {
        await player.dispose();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _opening++;
    unawaited(_closePlayer(stopStream: true));
    unawaited(proxy.dispose());
    super.dispose();
  }
}
