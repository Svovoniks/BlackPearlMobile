import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../connection/remote_link.dart';
import '../protocol/library.dart';
import '../storage/app_settings.dart';
import 'media_proxy.dart';

/// Where Sound on the phone is: off; asking the PC; on, with nothing to play yet (nothing plays on the PC, or the PC is
/// getting the sound ready); opening or refilling the sound; playing in step with the PC; or paused with it.
enum SoundPhase { off, starting, waiting, loading, playing, paused }

/// One `clock` answer: where the PC's picture was, timed by when the question went and when the answer came, on the
/// phone's own steady clock.
class ClockSample {
  const ClockSample({required this.sentMs, required this.receivedMs, required this.positionMs, required this.playing, this.source});

  final int sentMs;
  final int receivedMs;
  final int positionMs;
  final bool playing;

  /// The video the PC plays, as its sound stream names it; null when nothing plays.
  final String? source;

  int get roundTripMs => receivedMs - sentMs;

  /// Where the PC was as the answer arrived, taking the answer to have spent half the round trip on its way.
  int get positionAtReceipt => playing ? positionMs + roundTripMs ~/ 2 : positionMs;
}

/// Where the PC's picture is at any moment, from its `clock` answers. The answer with the shortest round trip is the one
/// whose guess about its time on the way is the best, so it is the one followed, until an answer says the PC has
/// jumped (a seek, a pause, another video), which starts over from that one.
class SoundClock {
  final List<ClockSample> _samples = [];

  ClockSample? get _best => _samples.isEmpty ? null : _samples.reduce((a, b) => b.roundTripMs < a.roundTripMs ? b : a);

  bool get known => _samples.isNotEmpty;

  /// The round trip of the answer followed, in milliseconds.
  int? get roundTripMs => _best?.roundTripMs;
  bool? get playing => _samples.lastOrNull?.playing;
  String? get source => _samples.lastOrNull?.source;

  void add(ClockSample sample) {
    if (sample.roundTripMs < 0) return;
    final expected = positionAt(sample.receivedMs);
    final last = _samples.lastOrNull;
    if (last != null &&
        (sample.source != last.source ||
            sample.playing != last.playing ||
            expected == null ||
            (sample.positionAtReceipt - expected).abs() > 80 + sample.roundTripMs ~/ 2)) {
      _samples.clear();
    }
    _samples.add(sample);
    // Clocks drift apart by milliseconds a minute; a minute-old answer is still good, but not forever.
    _samples.removeWhere((s) => sample.receivedMs - s.receivedMs > 60000);
    while (_samples.length > 12) {
      _samples.removeAt(0);
    }
  }

  /// The PC's position at [nowMs] on the phone's steady clock, or null before any answer.
  int? positionAt(int nowMs) {
    final best = _best;
    if (best == null) return null;
    return best.playing ? best.positionAtReceipt + (nowMs - best.receivedMs) : best.positionMs;
  }

  void clear() => _samples.clear();
}

/// What the player does about being [errorMs] ahead of the PC (behind when negative), playing at [rate] now: a seek
/// for a large gap, a slightly slower or faster speed for a small one, which no one hears, and the normal speed again
/// once in step.
({double rate, bool seek}) soundCorrection(int errorMs, double rate) {
  if (errorMs.abs() > PhoneSound.seekBeyondMs) return (rate: 1.0, seek: true);
  final correcting = rate != 1.0;
  // Stops a little past in step, and starts again only past a gap worth hearing, so it doesn't hunt.
  final settled = correcting ? errorMs.abs() <= 8 || (errorMs > 0) != (rate < 1.0) : errorMs.abs() < PhoneSound.inStepMs;
  if (settled) return (rate: 1.0, seek: false);
  final adjusted = (1.0 - errorMs / 4000).clamp(1.0 - PhoneSound.maxRateChange, 1.0 + PhoneSound.maxRateChange);
  return (rate: (adjusted * 1000).round() / 1000, seek: false);
}

/// Plays the PC's sound on the phone while the PC shows the picture, for headphones on the couch (PHONE-REMOTE.md,
/// "Sound on the phone"). The PC goes quiet and sends the sound of what it plays; the phone plays it through
/// [MediaProxy] as it plays videos, and keeps it in step with the PC's picture: it asks the PC where it is every
/// second and nudges its own speed by a few percent, or seeks when far off.
class PhoneSound extends ChangeNotifier {
  PhoneSound({
    required this.link,
    required this.settings,
    MediaProxy? proxy,
    Player Function()? createPlayer,
    this.keepAwake,
    int Function()? now,
  }) : _createPlayer = createPlayer ?? _defaultPlayer,
       _now = now ?? _steady {
    this.proxy = proxy ?? MediaProxy(reader: () => link.media, onLost: (_) => _lost());
    _pushes = link.pushes.listen(_pushed);
    link.addListener(_linkChanged);
    _wasConnected = link.status.isConnected;
  }

  /// A gap this large is closed by seeking; smaller ones by speed.
  static const seekBeyondMs = 200;

  /// Within this, the sound counts as in step and plays at normal speed.
  static const inStepMs = 35;

  /// The most the speed changes to catch up, either way.
  static const maxRateChange = 0.05;

  final RemoteLink link;
  final AppSettings settings;
  late final MediaProxy proxy;
  final Player Function() _createPlayer;
  final int Function() _now;

  /// Keeps the phone's processor and Wi-Fi awake while the sound plays with the screen off (Android); null elsewhere.
  final void Function(bool hold)? keepAwake;

  /// Debug builds only (`--sound-device=<mpv audio device>`): where the sound plays instead of the default output.
  static String? debugSoundDevice;

  /// Debug builds only (`--sound-log=<file>`): a line for every look at the gap, for checking how it closes.
  static void Function(String line)? debugLog;

  static final Stopwatch _watch = Stopwatch()..start();
  static int _steady() => _watch.elapsedMilliseconds;

  static Player _defaultPlayer() {
    final player = Player(
      configuration: const PlayerConfiguration(bufferSize: 8 * 1024 * 1024, title: 'BlackPearl sound'),
    );
    final native = player.platform;
    if (native is NativePlayer) {
      // AudioTrack knows how long the phone's output takes, Bluetooth included, so the position mpv reports is what is
      // heard; OpenSL ES, media_kit's default, doesn't.
      if (Platform.isAndroid) unawaited(native.setProperty('ao', 'audiotrack,opensles').catchError((_) {}));
      // Debug builds on a PC can play into another device, to measure the sound against the PC's picture.
      if (debugSoundDevice != null) unawaited(native.setProperty('audio-device', debugSoundDevice!).catchError((_) {}));
      unawaited(native.setProperty('vid', 'no').catchError((_) {}));
      unawaited(native.setProperty('network-timeout', '120').catchError((_) {}));
      unawaited(native.setProperty('demuxer-readahead-secs', '30').catchError((_) {}));
    }
    return player;
  }

  late final StreamSubscription<Map<String, dynamic>> _pushes;
  final SoundClock _clock = SoundClock();
  Player? _player;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  StreamInfo? _stream;
  Uri? _address;
  Timer? _ticker;
  Timer? _clockTimer;
  bool _wanted = false;
  bool _wasConnected = false;
  bool _ticking = false;
  bool _askingClock = false;
  int _opening = 0;
  int _holdUntil = 0;
  bool _afterSeek = false;
  double _rate = 1.0;
  int _lastClockAt = -1 << 40;

  /// How far ahead of where the PC is a seek aims, for the time the seek takes; learned from each seek.
  int _seekLeadMs = 250;

  SoundPhase _phase = SoundPhase.off;
  SoundPhase get phase => _phase;
  bool get on => _phase != SoundPhase.off;

  /// Why the sound stopped or is waiting, to show beside the switch; null when there's nothing to say.
  String? _message;
  String? get message => _message;

  /// How far the phone was ahead of the PC's picture at the last look, in milliseconds (behind when negative).
  int? _errorMs;
  int? get errorMs => _errorMs;

  /// Why the sound stopped when it wasn't this phone's choice (the PC took it back, or refused), for a snack bar.
  final ValueNotifier<String?> notice = ValueNotifier(null);

  /// Whether the PC can send its sound.
  bool get available => link.features.contains('sound');

  int _volume = 100;
  int get volume => _volume;
  bool _muted = false;
  bool get muted => _muted;

  String get statusText => switch (_phase) {
    SoundPhase.off => _message ?? 'Off',
    SoundPhase.starting => 'Asking the PC…',
    SoundPhase.waiting => _message ?? 'Waiting for the PC to play something',
    SoundPhase.loading => 'Getting the sound from the PC…',
    SoundPhase.paused => 'Paused on the PC',
    SoundPhase.playing => (_errorMs ?? 0).abs() > inStepMs ? 'Catching up with the picture' : 'Playing on this phone',
  };

  /// Asks the PC for its sound. The PC goes quiet once it sends it.
  Future<void> turnOn() async {
    if (_wanted) return;
    _wanted = true;
    _message = null;
    _setPhase(SoundPhase.starting);
    keepAwake?.call(true);
    _clockTimer ??= Timer.periodic(const Duration(seconds: 1), (_) => unawaited(_askClock()));
    _ticker ??= Timer.periodic(const Duration(milliseconds: 200), (_) => unawaited(_tick()));
    await _listen();
  }

  // Unanswered `listen` requests in a row.
  int _unanswered = 0;

  Future<void> _listen() async {
    try {
      await link.ask('listen', {'on': true}, timeout: const Duration(seconds: 10));
      _unanswered = 0;
      if (_wanted && _phase == SoundPhase.starting) _setPhase(SoundPhase.waiting);
      unawaited(_askClock());
    } on RemoteRequestException catch (e) {
      // Offline: the link asks again once it is back.
      if (e.code == 'offline' || !_wanted) return;
      if (e.code == 'timeout') {
        // Asked again, twice; then it gives up rather than wait (and hold the phone awake) for good.
        if (++_unanswered < 3) {
          unawaited(_listen());
        } else {
          _unanswered = 0;
          await turnOff(message: "The PC didn't send its sound. Try again.");
        }
        return;
      }
      await turnOff(message: e.message, tell: false);
    }
  }

  /// Stops the sound here; the PC plays it again. [message] says why, when it wasn't the user's choice.
  Future<void> turnOff({String? message, bool tell = true}) async {
    final was = _wanted;
    _wanted = false;
    // Told first, before anything here waits: the connection may be disposed right after (another PC chosen).
    if (was && tell && link.status.isConnected) {
      unawaited(link.ask('listen', {'on': false}, timeout: const Duration(seconds: 5)).then((_) {}, onError: (Object _) {}));
    }
    _ticker?.cancel();
    _ticker = null;
    _clockTimer?.cancel();
    _clockTimer = null;
    _clock.clear();
    _errorMs = null;
    _message = message;
    if (message != null && !_disposed) {
      notice.value = null;
      notice.value = message;
    }
    if (was) keepAwake?.call(false);
    await _closeStream();
    _setPhase(SoundPhase.off);
  }

  Future<void> toggle() => _wanted ? turnOff() : turnOn();

  Future<void> setVolume(int value) async {
    _volume = value.clamp(0, 100);
    if (_volume > 0) _muted = false;
    if (!_disposed) notifyListeners();
    await _player?.setVolume(_muted ? 0 : _volume.toDouble());
  }

  Future<void> toggleMute() async {
    _muted = !_muted;
    if (!_disposed) notifyListeners();
    await _player?.setVolume(_muted ? 0 : _volume.toDouble());
  }

  /// Moves the sound later (positive) or earlier, and saves it for next time.
  Future<void> adjustDelay(int byMs) => settings.setSoundDelayMs(settings.soundDelayMs + byMs);

  // ---- from the PC ----

  void _pushed(Map<String, dynamic> message) {
    if (message['type'] != 'sound' || !_wanted) return;
    final why = message['why'] is String && (message['why'] as String).isNotEmpty ? message['why'] as String : null;
    if (message['on'] == false) {
      unawaited(turnOff(message: why ?? 'The sound is back on the PC.', tell: false));
      return;
    }
    final stream = message['stream'];
    if (stream is! Map) {
      unawaited(_closeStream());
      _message = why;
      _setPhase(SoundPhase.waiting);
      return;
    }
    final id = stream['streamId'],
        source = stream['source'],
        segments = stream['segments'],
        segmentMs = stream['segmentMs'],
        duration = stream['durationMs'];
    if (id is! String || source is! String || segments is! num || segments <= 0 || segmentMs is! num || segmentMs <= 0) return;
    if (_stream?.streamId == id) return;
    unawaited(
      _open(
        StreamInfo(
          id: source,
          title: 'Sound',
          hls: true,
          streamId: id,
          segments: segments.round(),
          segmentMs: segmentMs.round(),
          durationMs: duration is num ? duration.round() : 0,
        ),
      ),
    );
  }

  void _linkChanged() {
    final status = link.status;
    // The link stopped (Disconnect, or the app closed without the background service) or gave up on a failure only
    // the user can fix: the sound stops here, and the phone lets go of its locks. A link that is retrying keeps it.
    if (_wanted && (status.phase == LinkPhase.idle || status.phase == LinkPhase.failed && status.retryAt == null)) {
      unawaited(turnOff(message: 'The link to the PC stopped, so the sound is back on the PC.', tell: false));
      _wasConnected = false;
      return;
    }
    final connected = status.isConnected;
    if (connected && !_wasConnected && _wanted && !available) {
      // Back with a PC that can't send its sound: BlackPearl closed on it, and its phone host has no player.
      _wasConnected = true;
      unawaited(turnOff(message: "The PC can't send its sound now: BlackPearl isn't open on it.", tell: false));
      return;
    }
    if (connected && !_wasConnected && _wanted) {
      // Back after a drop: the PC kept the sound for this phone a while; asking again keeps it, or starts it again.
      unawaited(_listen());
    }
    _wasConnected = connected;
    // A state follows every seek and pause on the PC: look where it is now rather than at the next second.
    if (_wanted && connected && _now() - _lastClockAt > 300) unawaited(_askClock());
  }

  // The PC no longer has the stream, or the link stayed down too long: ask for the sound again.
  void _lost() {
    if (!_wanted) return;
    unawaited(_closeStream());
    _setPhase(SoundPhase.waiting);
    unawaited(_listen());
  }

  Future<void>? _clockAsk;
  // One question at a time; asking again while one is out waits for that one.
  Future<void> _askClock() => _clockAsk ??= _askClockNow().whenComplete(() => _clockAsk = null);

  Future<void> _askClockNow() async {
    if (!_wanted || _askingClock || !link.status.isConnected) return;
    _askingClock = true;
    final sent = _now();
    _lastClockAt = sent;
    try {
      final answer = await link.ask('clock', {}, timeout: const Duration(seconds: 3));
      final position = answer['positionMs'];
      if (position is! num) return;
      _clock.add(
        ClockSample(
          sentMs: sent,
          receivedMs: _now(),
          positionMs: position.round(),
          playing: answer['playing'] == true,
          source: answer['source'] is String ? answer['source'] as String : null,
        ),
      );
    } catch (_) {
      // The next second asks again.
    } finally {
      _askingClock = false;
    }
  }

  // ---- the player ----

  Future<void> _open(StreamInfo stream) async {
    final opening = ++_opening;
    await _closeStream(keepPlayer: true);
    if (opening != _opening || !_wanted) return;
    _stream = stream;
    _errorMs = null;
    _message = null;
    _setPhase(SoundPhase.loading);
    final address = await proxy.open(stream);
    if (opening != _opening || !_wanted || _stream != stream) {
      proxy.close(address);
      return;
    }
    _address = address;
    // A fresh look at where the PC is, to start there: the first answers about a new video can still be about the last.
    for (var tries = 0; tries < 4 && _clock.source != stream.id; tries++) {
      await _askClock();
      if (opening != _opening || !_wanted) return;
      if (_clock.source != stream.id) await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await _askClock();
    if (opening != _opening || !_wanted) return;
    final player = _player ??= _newPlayer();
    final target = _clock.source == stream.id ? _clock.positionAt(_now()) : null;
    final start = target == null ? 0 : max(0, target - settings.soundDelayMs + _seekLeadMs);
    _rate = 1.0;
    // Turned off (or another stream opened) while this waits on the player, which may be disposed by then: media_kit
    // throws an AssertionError for a disposed player's calls, so each step looks first.
    bool current() => opening == _opening && _wanted && identical(_player, player);
    try {
      await player.setRate(1.0);
      if (!current()) return;
      await player.setVolume(_muted ? 0 : _volume.toDouble());
      if (!current()) return;
      await player.open(
        Media(address.toString(), start: start > 0 ? Duration(milliseconds: start) : null),
        play: _clock.playing != false,
      );
    } catch (_) {
      if (current()) rethrow;
      return;
    }
    // Opening waits for the PC to start converting, which a seek in the same sound doesn't: it teaches the lead nothing.
    _afterSeek = false;
    _holdUntil = _now() + 1200;
  }

  Player _newPlayer() {
    final player = _createPlayer();
    _subscriptions.add(player.stream.error.listen((_) {}));
    return player;
  }

  Future<void> _closeStream({bool keepPlayer = false}) async {
    final address = _address;
    _address = null;
    _stream = null;
    if (address != null) proxy.close(address);
    final player = _player;
    if (player == null) return;
    if (keepPlayer) {
      await player.stop();
      return;
    }
    _player = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    await player.dispose();
  }

  Future<int?> _position(Player player) async {
    final native = player.platform;
    if (native is NativePlayer) {
      final value = double.tryParse(await native.getProperty('time-pos', waitForInitialization: false));
      if (value != null) return (value * 1000).round();
    }
    return player.state.position.inMilliseconds;
  }

  Future<void> _seek(Player player, int toMs) async {
    _rate = 1.0;
    await player.setRate(1.0);
    await player.seek(Duration(milliseconds: max(0, toMs)));
  }

  // Five times a second: follows the PC's play and pause, and closes any gap to its picture.
  Future<void> _tick() async {
    final player = _player, stream = _stream;
    if (_ticking || player == null || stream == null || !_wanted) return;
    _ticking = true;
    try {
      final now = _now();
      final pc = _clock.positionAt(now);
      // An answer about another video: its sound is on its way.
      if (pc == null || _clock.source != stream.id) return;
      final target = pc - settings.soundDelayMs;
      if (_clock.playing == false) {
        if (player.state.playing) await player.pause();
        final position = await _position(player);
        if (position != null && (position - target).abs() > 150) await _seek(player, target);
        _errorMs = null;
        _setPhase(SoundPhase.paused);
        return;
      }
      // Just opened or seeked: it settles first.
      if (now < _holdUntil) return;
      // The sound ended before the PC's video did (credits without sound, or a shorter track): nothing to catch up to.
      if (player.state.completed && target >= stream.durationMs - 1000) return;
      if (!player.state.playing) {
        // Playing again with the PC: straight to where the picture is, rather than catching up from where it paused.
        await _seek(player, target + _seekLeadMs);
        await player.play();
        _afterSeek = true;
        _holdUntil = _now() + 800;
        return;
      }
      if (player.state.buffering) {
        _setPhase(SoundPhase.loading);
        return;
      }
      final position = await _position(player);
      if (position == null) return;
      final error = position - (target + (_now() - now));
      _errorMs = error;
      // How long the seek took shows in where it landed; the next one aims that much further.
      if (_afterSeek) {
        _afterSeek = false;
        if (error.abs() < 1500) _seekLeadMs = (_seekLeadMs - (error * 0.6).round()).clamp(0, 3000);
      }
      final correction = soundCorrection(error, _rate);
      debugLog?.call(
        'pc=$pc target=$target phone=$position error=$error rate=$_rate rtt=${_clock.roundTripMs} lead=$_seekLeadMs ${correction.seek ? 'seek' : 'rate=${correction.rate}'}',
      );
      if (correction.seek) {
        await _seek(player, target + _seekLeadMs);
        _afterSeek = true;
        _holdUntil = _now() + 1200;
        _setPhase(SoundPhase.loading);
        return;
      }
      if (correction.rate != _rate) {
        _rate = correction.rate;
        await player.setRate(_rate);
      }
      _setPhase(SoundPhase.playing);
    } catch (_) {
      // A player closing under the tick; the next one looks again.
    } finally {
      _ticking = false;
    }
  }

  // Told only when something shown changes: the tick sets the phase five times a second.
  String? _shown;
  bool _disposed = false;
  void _setPhase(SoundPhase phase) {
    _phase = phase;
    final shown = '$phase $statusText';
    if (shown == _shown || _disposed) return;
    _shown = shown;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    link.removeListener(_linkChanged);
    unawaited(_pushes.cancel());
    unawaited(turnOff());
    unawaited(proxy.dispose());
    notice.dispose();
    super.dispose();
  }
}
