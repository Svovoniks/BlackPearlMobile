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
    this.proxy = proxy ?? MediaProxy(reader: () => link.media, onLost: _streamLost);
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

  // One "viewing" per time the player screen opens; a quality change or a recovery stays in the same viewing. Whoever
  // opened a viewing stops only that one, so a late cleanup never stops the next video.
  int _viewing = 0;
  int startViewing() => ++_viewing;

  // `watch` requests the PC hasn't answered yet.
  int _asking = 0;

  /// A short message for the player to show, such as a quality change that didn't work.
  final ValueNotifier<String?> notice = ValueNotifier(null);

  // Recoveries of a stream that stopped: the times they started, to give up after a few in a short while.
  final List<DateTime> _recoveries = [];

  String get _network => switch (link.status.path) {
    NetworkPath.home => 'home',
    NetworkPath.relayed => 'relayed',
    _ => 'away',
  };

  /// Starts [id] on the phone. [takeOver]: it's the video the PC plays now; the PC stops and the phone continues from
  /// where it was. [quality] overrides the automatic choice; [startAt] the PC's resume point.
  Future<bool> watch(String id, {bool takeOver = false, String? quality, int? startAt}) async {
    final attempt = ++_opening;
    // Another stream of the video on screen (a quality change, a recovery): the old one plays on until the new one is
    // ready, and stays if the new one can't be had.
    final replacing = _stream?.id == id && _player != null;
    _handedOver = false;
    if (!replacing) {
      await _report(final_: true);
      _phase = PhonePlaybackPhase.opening;
      _error = null;
      notifyListeners();
    }
    final StreamInfo? info;
    _asking++;
    try {
      final reply = await link.ask('watch', {
        'id': id,
        'quality': quality ?? (_network == 'home' ? 'auto' : awayQuality),
        'network': _network,
        'takeOver': takeOver,
      }, timeout: const Duration(seconds: 45));
      info = StreamInfo.fromJson(reply);
    } on RemoteRequestException catch (e) {
      if (attempt == _opening) {
        if (replacing && _player != null) {
          _say(e.message);
        } else {
          _fail(e.message);
        }
      }
      return false;
    } finally {
      _asking--;
    }
    if (attempt != _opening) {
      // An answer nobody waits for any more: the PC holds a stream for it, which nothing will read. Let it go, unless
      // a newer request or stream is the PC's current one now.
      if (_asking == 0 && _stream == null && _player == null) link.tell('stream-stop', {});
      return false;
    }
    if (info == null) {
      if (replacing && _player != null) {
        _say("The PC's answer didn't say how to play the video.");
      } else {
        _fail("The PC's answer didn't say how to play the video.");
      }
      return false;
    }
    final stalledAt = _stalledAt;
    _endRecovery();
    // Another quality of the same video replaces the player on screen: the new one takes over before the old one goes.
    final previous = _detachPlayer();
    _stream = info;
    _ended = false;
    _lastReported = -1;
    final player = _player = _createPlayer();
    _listen(player);
    final address = _address = await proxy.open(info);
    final start = startAt ?? info.positionMs;
    await player.open(Media(address.toString(), start: start > 0 ? Duration(milliseconds: start) : null));
    if (previous != null) unawaited(Future<void>.delayed(const Duration(milliseconds: 500), () => _release(previous)));
    // The same spot running out again on a fresh stream is where the file itself ends.
    _endsAt = stalledAt;
    if (attempt != _opening) return true;
    _phase = PhonePlaybackPhase.playing;
    notifyListeners();
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_player?.state.playing == true) unawaited(_report());
    });
    return true;
  }

  // Where a recovered stream started; data running out there again means the file is shorter than its header says.
  int? _endsAt;

  /// Opens the same video again at another quality, from where it is now.
  Future<void> changeQuality(String quality) async {
    final current = _stream;
    if (current == null) return;
    final position = _player?.state.position.inMilliseconds ?? current.positionMs;
    await watch(current.id, quality: quality, startAt: position);
  }

  void _say(String text) {
    notice.value = null;
    notice.value = text;
  }

  // Where the video stopped when the data ran out, while it waits to be fetched again; null while it plays. Until a new
  // stream plays, nothing is reported: a finished libmpv player starts again from 0:00 when Play is pressed.
  int? _stalledAt;
  Timer? _retryTimer, _giveUpTimer;
  bool _waitingForLink = false;

  /// The player ran out of video before its end: the PC gave the stream up (the phone was away longer than it waits)
  /// or the link failed. Ask for it again from where it stopped. While the link is down it waits for it to come back,
  /// for up to three minutes; a request that fails is tried again. After a few tries in a short while, it says so.
  Future<void> _recover() async {
    final stream = _stream;
    if (stream == null || _player == null || _stalledAt == null) return;
    _retryTimer?.cancel();
    if (!link.status.isConnected) {
      _waitForLink();
      return;
    }
    final now = DateTime.now();
    _recoveries.removeWhere((at) => now.difference(at) > const Duration(minutes: 2));
    if (_recoveries.length >= 3) {
      _endRecovery();
      _fail('The video stopped coming from the PC. Check the connection and try again.');
      return;
    }
    _recoveries.add(now);
    final ok = await watch(stream.id, quality: stream.quality, startAt: _stalledAt);
    // Still the stalled stream: try again shortly (or once the link is back), within the same budget.
    if (!ok && identical(_stream, stream) && _stalledAt != null) _retryTimer = Timer(const Duration(seconds: 5), () => unawaited(_recover()));
  }

  void _waitForLink() {
    if (_waitingForLink) return;
    _waitingForLink = true;
    link.addListener(_linkChanged);
    _giveUpTimer ??= Timer(const Duration(minutes: 3), () {
      if (_stalledAt == null) return;
      _endRecovery();
      _fail('Lost the connection to the PC. Open the video again from the Library to carry on where it stopped.');
    });
  }

  void _linkChanged() {
    if (!link.status.isConnected) return;
    link.removeListener(_linkChanged);
    _waitingForLink = false;
    unawaited(_recover());
  }

  void _endRecovery() {
    _retryTimer?.cancel();
    _giveUpTimer?.cancel();
    _giveUpTimer = null;
    if (_waitingForLink) link.removeListener(_linkChanged);
    _waitingForLink = false;
    _stalledAt = null;
  }

  /// The proxy found the PC's stream gone, or the link down for too long: recover from where the player is.
  void _streamLost(StreamInfo lost) {
    final player = _player;
    // A read of a stream already replaced (another quality) failing is no news.
    if (!identical(lost, _stream) || player == null || _stalledAt != null || _phase != PhonePlaybackPhase.playing) return;
    _stalledAt = player.state.position.inMilliseconds;
    unawaited(_recover());
  }

  /// Whether a position is the end of the video rather than where the data ran out.
  bool _atEnd(Player player) {
    var duration = player.state.duration.inMilliseconds;
    if (duration <= 0) duration = _stream?.durationMs ?? 0;
    return duration <= 0 || player.state.position.inMilliseconds >= duration - 15000;
  }

  void _listen(Player player) {
    _subscriptions.add(player.stream.playing.listen((playing) {
      // A pause is a natural moment to save where the phone is.
      if (!playing) unawaited(_report());
      notifyListeners();
    }));
    _subscriptions.add(player.stream.completed.listen((completed) {
      if (!completed || _stream == null || !identical(player, _player)) return;
      // libmpv also says "completed" when the data runs out mid-video.
      final position = player.state.position.inMilliseconds;
      final shortFile = _endsAt != null && (position - _endsAt!).abs() < 3000;
      if (!_atEnd(player) && !shortFile) {
        _stalledAt ??= position;
        unawaited(_recover());
        return;
      }
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
    if (stream == null || player == null || _stalledAt != null) return;
    final position = player.state.position.inMilliseconds;
    var duration = player.state.duration.inMilliseconds;
    if (duration <= 0) duration = stream.durationMs;
    if (position <= 0 && !_ended) return;
    if (!final_ && !_ended && (position - _lastReported).abs() < 1000) return;
    _lastReported = position;
    link.tell('progress', {'id': stream.id, 'positionMs': position, 'durationMs': duration, 'ended': _ended, 'final': final_});
  }

  /// Continue on the PC: the phone pauses, and the PC plays the video from the same moment. The caller leaves the
  /// player and then calls [stop], which lets the phone's player go.
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
    _handedOver = true;
    return null;
  }

  bool _handedOver = false;

  /// Stops playing on the phone, saving where it got to. Call it once the player is off screen: libmpv's picture
  /// must not be in use when it goes. With [viewing], only that viewing stops; a newer one plays on.
  Future<void> stop({int? viewing}) async {
    if (viewing != null && viewing != _viewing) return;
    // A stall in progress: the PC keeps the position it last heard, not the stalled player's.
    final stalled = _stalledAt != null;
    _endRecovery();
    _endsAt = null;
    _opening++;
    _recoveries.clear();
    // The PC plays it now and keeps its own position.
    if (!_handedOver && !stalled) await _report(final_: true);
    _handedOver = false;
    final previous = _detachPlayer();
    if (_stream != null) link.tell('stream-stop', {});
    _stream = null;
    _phase = PhonePlaybackPhase.idle;
    _error = null;
    notifyListeners();
    if (previous != null) await _release(previous);
  }

  /// The app went to the background: the video waits, and the PC learns where it is.
  Future<void> background() async {
    final player = _player;
    if (player == null) return;
    if (player.state.playing) await player.pause();
    await _report(final_: true);
  }

  void _fail(String message) {
    // Whatever was playing stops: the error covers the screen.
    final previous = _detachPlayer();
    if (previous != null) unawaited(Future<void>.delayed(const Duration(milliseconds: 500), () => _release(previous)));
    _phase = PhonePlaybackPhase.failed;
    _error = message;
    notifyListeners();
  }

  /// Takes the player and its address off this object, to release once nothing shows it.
  (Player, Uri?)? _detachPlayer() {
    _progressTimer?.cancel();
    _progressTimer = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    final player = _player;
    final address = _address;
    _player = null;
    _address = null;
    return player == null ? null : (player, address);
  }

  Future<void> _release((Player, Uri?) previous) async {
    final (player, address) = previous;
    if (address != null) proxy.close(address);
    try {
      await player.dispose();
    } catch (_) {}
  }

  @override
  void dispose() {
    _endRecovery();
    _opening++;
    final previous = _detachPlayer();
    if (_stream != null) link.tell('stream-stop', {});
    _stream = null;
    if (previous != null) unawaited(_release(previous));
    unawaited(proxy.dispose());
    notice.dispose();
    super.dispose();
  }
}
