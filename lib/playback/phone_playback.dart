import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../connection/remote_link.dart';
import '../connection/transport.dart';
import '../protocol/library.dart';
import 'media_proxy.dart';
import 'shuffle_order.dart';
import 'track_languages.dart';

/// What the phone's player does: what it opened, and how it's going.
enum PhonePlaybackPhase { idle, opening, playing, failed }

/// A change the player is waiting on the PC for: another quality of the video on screen, or another episode.
class PendingSwitch {
  const PendingSwitch.quality(String this.quality) : episode = null, audio = null, audioName = null;
  const PendingSwitch.episode(EpisodeStep this.episode) : quality = null, audio = null, audioName = null;
  /// Another audio track of a conversion, which the PC converts again with: its id in [PhonePlayback.audioTracks], and
  /// what to call it.
  const PendingSwitch.audio(String this.audio, String this.audioName) : quality = null, episode = null;
  final String? quality;
  final EpisodeStep? episode;
  final String? audio;
  final String? audioName;

  String get label => quality != null
      ? 'Switching to ${qualityLabel(quality!)}…'
      : audio != null
      ? 'Switching to $audioName…'
      : 'Opening ${episode!.detail ?? episode!.title}…';
}

/// The next episode, offered when one ends; it plays when [deadline] passes unless the offer is canceled.
class UpNextOffer {
  const UpNextOffer({required this.step, required this.deadline, required this.length});
  final EpisodeStep step;
  final DateTime deadline;
  final Duration length;
}

/// Plays a PC's video on the phone (PHONE-REMOTE.md, "Watching on the phone"). The PC sends the video over the link;
/// [MediaProxy] hands it to libmpv. How far the phone gets goes back to the PC as `progress`, so Continue watching
/// and the watched marks are the same on both.
class PhonePlayback extends ChangeNotifier {
  PhonePlayback({required this.link, MediaProxy? proxy, Player Function()? createPlayer, this.awayQuality = 'auto'})
    : _createPlayer = createPlayer ?? _defaultPlayer {
    // While the phone waits for an answer, new reads hold back for up to 4 seconds; the player plays from its cache.
    this.proxy = proxy ?? MediaProxy(reader: () => link.media, onLost: _streamLost, beforeRead: () => link.answered(const Duration(seconds: 4)));
  }

  final RemoteLink link;
  late final MediaProxy proxy;
  final Player Function() _createPlayer;

  /// The quality asked for away from home: `auto`, `original`, `1080p`, `720p` or `480p`.
  String awayQuality;

  /// Loop, as on the PC: `off`, `all` (after a show's last episode its first plays) or `one` (the video replays).
  String loopMode = 'off';

  /// How long the up-next countdown runs, as on the PC.
  static const upNextLength = Duration(seconds: 15);

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

  /// The player of [viewing] was left: a video still waiting to be asked for is no longer asked for, and one already
  /// asked for is let go when its answer comes. One that opened plays on until [stop].
  void cancelOpening(int viewing) {
    if (viewing == _viewing && _phase == PhonePlaybackPhase.opening && _stream == null) _opening++;
  }

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
  /// where it was. [quality] overrides the automatic choice; [startAt] the PC's resume point. [step]: another episode
  /// of this viewing, which the player shows it is opening.
  ///
  /// One player serves the whole viewing: another quality, a recovery or another episode opens on the player already
  /// on screen. A second player got no video surface on Android, and libmpv took that for the end of the video.
  ///
  /// [audio]: for a conversion, the file's audio track to convert with. Another stream of the video on screen keeps the
  /// track playing now unless [audio] names another; a new video starts with the one the PC's preferences pick.
  Future<bool> watch(String id, {bool takeOver = false, String? quality, int? startAt, EpisodeStep? step, QueueRef? queue, int? audio}) async {
    final attempt = ++_opening;
    final hadPlayer = _player != null;
    // Another stream of the video on screen (a quality change, a recovery): the old one plays on until the new one is
    // ready, and stays if the new one can't be had.
    final replacing = _stream?.id == id && hadPlayer;
    if (replacing) audio ??= await _playingAudioIndex();
    _handedOver = false;
    _switching = true;
    if (!replacing) {
      await _report(final_: true);
      _endUpNext();
      if (hadPlayer) {
        // Another episode: the last picture stays until the next one opens.
        unawaited(_player!.pause().catchError((_) {}));
        _setPending(PendingSwitch.episode(step ?? EpisodeStep(id: id, title: 'the next video')));
      } else {
        _phase = PhonePlaybackPhase.opening;
        _error = null;
        notifyListeners();
      }
    } else if (quality != null && !_recovering && pending.value?.audio == null) {
      _setPending(PendingSwitch.quality(quality));
    }
    final StreamInfo? info;
    _asking++;
    try {
      // The link may be coming back, as after the app was in the background: wait for it a while.
      if (!link.status.isConnected) await _whenConnected(const Duration(seconds: 20));
      if (attempt != _opening) return false;
      final reply = await link.ask('watch', {
        'id': id,
        'quality': quality ?? (_network == 'home' ? 'auto' : awayQuality),
        'network': _network,
        'takeOver': takeOver,
        // A video played as part of a queue: the PC's Previous, Next and Loop all follow the queue.
        if ((queue ?? (replacing ? _followed : null)) case final inQueue?) ...{'queue': inQueue.id, 'queueIndex': ?inQueue.index},
        'audio': ?audio,
      }, timeout: const Duration(seconds: 45));
      info = StreamInfo.fromJson(reply);
    } on RemoteRequestException catch (e) {
      if (attempt == _opening) {
        _switching = false;
        _setPending(null);
        if (hadPlayer && _stream != null) {
          _lastRefusal = e.message;
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
      _switching = false;
      _setPending(null);
      if (hadPlayer && _stream != null) {
        _say("The PC's answer didn't say how to play the video.");
      } else {
        _fail("The PC's answer didn't say how to play the video.");
      }
      return false;
    }
    final stalledAt = _stalledAt;
    final playedBeforeStall = _playedBeforeStall;
    _endRecovery();
    final previousAddress = _address;
    if (!replacing) {
      // Track choices belong to a video; another episode starts from the PC's preferences again.
      _chosenAudio = null;
      _chosenSubtitle = null;
    }
    _stream = info;
    // Another video's answer says what comes next; another stream of this one keeps the list the player follows, unless
    // a list asked for it (the same video at another place of a queue).
    if (!replacing || queue != null) {
      _listSteps = null;
      _followed = info.queue;
    }
    _ensureShuffleList();
    _ended = false;
    _lastReported = -1;
    // Another stream of the video on screen, which played on while the PC got it ready, starts where the old one is now
    // rather than where it was when it was asked for. (A stalled one, from where it stopped.)
    final old = _player;
    final start = replacing && stalledAt == null && old != null && _positionKnown ? _positionOf(old) : startAt ?? info.positionMs;
    _openedAt = start;
    _positionKnown = false;
    _tracksApplied = false;
    _defaultSubtitle = null;
    final player = _player ??= _newPlayer();
    final address = _address = await proxy.open(info);
    _tracks = const Tracks();
    // Another stream of the video on screen plays on only if it was playing: a video paused by hand stays paused through
    // a quality change or a recovery. (A stalled one was playing until its data ran out, unless it was paused before.)
    final play = !replacing || (stalledAt != null ? playedBeforeStall : player.state.playing);
    await player.open(Media(address.toString(), start: start > 0 ? Duration(milliseconds: start) : null), play: play && !_inBackground);
    _switching = false;
    // In the background a new video waits to play until the app is back; another stream of this one keeps what going to
    // the background decided.
    if (_inBackground && !replacing) _resumeOnReturn = true;
    // The old stream's address goes once the player has let it go.
    if (previousAddress != null && previousAddress != address) {
      unawaited(Future<void>.delayed(const Duration(seconds: 2), () => proxy.close(previousAddress)));
    }
    // The same spot running out again on a fresh stream is where the file itself ends. Another video's stall says
    // nothing about this one: taken as its end, it marked a video watched where the last one had stalled.
    _endsAt = replacing ? stalledAt : null;
    if (attempt != _opening) return true;
    _setPending(null, notify: false);
    _phase = PhonePlaybackPhase.playing;
    notifyListeners();
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_player?.state.playing == true) unawaited(_report());
    });
    return true;
  }

  Player _newPlayer() {
    final player = _createPlayer();
    _listen(player);
    return player;
  }

  // From asking for another stream until it has opened, the old one running out is not the video's end.
  bool _switching = false;

  /// What the player waits on the PC for, to show it.
  final ValueNotifier<PendingSwitch?> pending = ValueNotifier(null);
  void _setPending(PendingSwitch? value, {bool notify = true}) {
    pending.value = value;
    if (notify) notifyListeners();
  }

  // The quality the user chose in this viewing; the next episode opens at it too.
  String? _chosenQuality;

  // Where a recovered stream started; data running out there again means the file is shorter than its header says.
  int? _endsAt;

  // Where the current player opened, and whether it has said where it is since. media_kit reports 0:00 until libmpv
  // has loaded and seeked, so until then the opening position is the player's.
  int _openedAt = 0;
  bool _positionKnown = false;
  int _positionOf(Player player) => _positionKnown ? player.state.position.inMilliseconds : _openedAt;

  /// Whether the player has said where it is since it opened; until then it is at [openedAtMs].
  bool get positionKnown => _positionKnown;
  int get openedAtMs => _openedAt;

  String? _lastRefusal;
  bool _recovering = false;

  /// Opens the same video again at another quality, from where it is now.
  Future<void> changeQuality(String quality) async {
    final current = _stream;
    if (current == null || pending.value?.quality == quality || pending.value?.episode != null) return;
    // Another audio track on its way finishes first: it is converted at the quality playing now.
    if (pending.value?.audio != null) {
      if (quality != current.quality) _say('Wait for the switch to ${pending.value!.audioName} to finish, then pick the quality.');
      return;
    }
    if (pending.value == null && quality == current.quality) return;
    final player = _player;
    // Where it stopped while stalled; the opening position until the player has said where it is.
    final position = _stalledAt ?? (player == null ? current.positionMs : _positionOf(player));
    // The next episode opens at the quality chosen here, once the PC has given it.
    if (await watch(current.id, quality: quality, startAt: position)) _chosenQuality = quality;
  }

  /// Waits until the link is connected, or [limit] has passed.
  Future<void> _whenConnected(Duration limit) {
    if (link.status.isConnected) return Future.value();
    final done = Completer<void>();
    void check() {
      if (link.status.isConnected && !done.isCompleted) done.complete();
    }

    link.addListener(check);
    final timer = Timer(limit, () {
      if (!done.isCompleted) done.complete();
    });
    return done.future.whenComplete(() {
      timer.cancel();
      link.removeListener(check);
    });
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
    // Three minutes from the stall at most, however the tries go.
    // In the background, where the link may stop altogether, the video waits for the app to come back and gets its three
    // minutes from then: it used them up and ended in an error, however briefly the user had looked away.
    if (!_inBackground) {
      _giveUpTimer ??= Timer(const Duration(minutes: 3), () => _giveUp(link.status.isConnected
          ? _lastRefusal ?? 'The video stopped coming from the PC. Check the connection and try again.'
          : 'Lost the connection to the PC. Open the video again from the Library to carry on where it stopped.'));
    }
    // One request at a time; another one (a quality change) in flight brings its own new stream, or tries again later.
    if (_recovering || _asking > 0) {
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(seconds: 5), () => unawaited(_recover()));
      return;
    }
    if (!link.status.isConnected) {
      _waitForLink();
      return;
    }
    final now = DateTime.now();
    _recoveries.removeWhere((at) => now.difference(at) > const Duration(minutes: 2));
    if (_recoveries.length >= 3) {
      _giveUp(_lastRefusal ?? 'The video stopped coming from the PC. Check the connection and try again.');
      return;
    }
    _recoveries.add(now);
    _recovering = true;
    final bool ok;
    try {
      ok = await watch(stream.id, quality: stream.quality, startAt: _stalledAt);
    } finally {
      _recovering = false;
    }
    // Still the stalled stream: try again shortly (or once the link is back), within the same budget.
    if (!ok && identical(_stream, stream) && _stalledAt != null) {
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(seconds: 5), () => unawaited(_recover()));
    }
  }

  void _giveUp(String message) {
    if (_stalledAt == null) return;
    _endRecovery();
    // A request still in flight is answered to nobody, and the PC lets the stream go now rather than when the error is
    // dismissed.
    _opening++;
    _fail(message);
    if (_stream != null) link.tell('stream-stop', {});
    _stream = null;
  }

  void _waitForLink() {
    if (_waitingForLink) return;
    _waitingForLink = true;
    link.addListener(_linkChanged);
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
    _lastRefusal = null;
  }

  /// The proxy found the PC's stream gone, or the link down for too long: recover from where the player is.
  void _streamLost(StreamInfo lost) {
    final player = _player;
    // A read of a stream already replaced (another quality) failing is no news, nor is one while a new stream of the same
    // video is being asked for: the PC lets the old one go before it answers.
    if (!identical(lost, _stream) || player == null || _stalledAt != null || _phase != PhonePlaybackPhase.playing || _asking > 0 || _handedOver) return;
    _stalledAt = _positionOf(player);
    _playedBeforeStall = player.state.playing;
    _lastRefusal = null;
    unawaited(_recover());
  }

  // Whether the video played when its stream stalled, rather than waited paused: the new stream does the same.
  bool _playedBeforeStall = true;

  // The file's tracks as libmpv last listed them. At the end of a file media_kit empties its list, and libmpv, which
  // keeps the file open, doesn't list them again when it plays on (Loop one, Previous, a seek back): the list stays here.
  Tracks _tracks = const Tracks();

  /// The tracks of the video on screen.
  Tracks get tracks => _tracks;

  /// Whether a position is the end of the video rather than where the data ran out.
  bool _atEnd(Player player) {
    var duration = player.state.duration.inMilliseconds;
    if (duration <= 0) duration = _stream?.durationMs ?? 0;
    return duration <= 0 || player.state.position.inMilliseconds >= duration - 15000;
  }

  void _listen(Player player) {
    _subscriptions.add(player.stream.position.listen((position) {
      // Not the old stream's, while another of this video opens: until the new one has said where it is, the player is at
      // the place it opened at (media_kit reports 0:00 meanwhile).
      if (position > Duration.zero && identical(player, _player) && !_switching) _positionKnown = true;
    }));
    _subscriptions.add(player.stream.playing.listen((playing) {
      // A pause is a natural moment to save where the phone is.
      if (!playing) unawaited(_report());
      // Playing again, as after going back from the end, cancels the up-next countdown.
      if (playing && upNext.value != null) _endUpNext();
      notifyListeners();
    }));
    _subscriptions.add(player.stream.completed.listen((completed) {
      if (_stream == null || !identical(player, _player) || _switching || _handedOver) return;
      // Seeking back or playing again after the end: the next end counts again.
      if (!completed) {
        _ended = false;
        return;
      }
      // libmpv also says "completed" when the data runs out mid-video.
      final position = _positionOf(player);
      final shortFile = _endsAt != null && (position - _endsAt!).abs() < 3000;
      if (!_atEnd(player) && !shortFile) {
        if (_stalledAt == null) {
          _stalledAt = position;
          // It played up to where the data ran out.
          _playedBeforeStall = true;
          _lastRefusal = null;
        }
        unawaited(_recover());
        return;
      }
      if (_ended) return;
      _ended = true;
      unawaited(_report(final_: true));
      _videoEnded();
      notifyListeners();
    }));
    _subscriptions.add(player.stream.tracks.listen((tracks) {
      bool any(Iterable<String> ids) => ids.any((id) => id != 'auto' && id != 'no');
      final listed = any(tracks.video.map((t) => t.id)) || any(tracks.audio.map((t) => t.id)) || any(tracks.subtitle.map((t) => t.id));
      if (listed && identical(player, _player)) _tracks = tracks;
      unawaited(_applyTrackPreferences());
    }));
    _subscriptions.add(player.stream.error.listen((message) {
      if (kDebugMode) debugPrint('player: $message');
    }));
  }

  // ---- Episodes, Loop and up next ----

  EpisodeStep? get previousEpisode => _shuffleReady ? _shuffledStep(forward: false) : _listSteps != null ? _listSteps!.previous : _stream?.previous;
  EpisodeStep? get nextEpisode => _shuffleReady ? _shuffledStep(forward: true) : _listSteps != null ? _listSteps!.next : _stream?.next;
  // Shuffle starts a new round with Loop all instead of going back to the first.
  EpisodeStep? get _firstEpisode => _shuffleReady ? null : _listSteps != null ? _listSteps!.first : _stream?.first;

  // ---- Shuffle ----

  bool _shuffle = false;

  /// Shuffle, as on the PC: Next, Previous and up next follow a random order of the show's regular episodes, or of the
  /// queue's videos, each once; Loop all then starts a new round. Needs a PC that lists its shows and queues.
  bool get shuffle => _shuffle;
  set shuffle(bool value) {
    if (value == _shuffle) return;
    _shuffle = value;
    _shuffleOrder.reset();
    // Turned on again, it asks for a list the PC couldn't give before.
    _shuffleFailed = null;
    _ensureShuffleList();
    notifyListeners();
  }

  /// Whether the PC can list what shuffle picks from (BrowseRequest.episodesOf and queue).
  bool get canShuffle => link.features.contains('queues');
  bool get _shuffling => _shuffle && canShuffle;

  // Shuffle steps once it has its list, or while it waits for one; a list the PC couldn't give leaves the usual order.
  bool get _shuffleReady => _shuffling && _shuffleFailed != _wantedShuffleList;
  String? _shuffleFailed;

  /// Whether the video is part of a show or a queue, so Previous and Next have somewhere to go.
  bool get inList => _followed != null || _stream?.previous != null || _stream?.next != null || _stream?.first != null;

  final ShuffleOrder _shuffleOrder = ShuffleOrder();
  // The list shuffle picks from: a queue's videos, or a show's episodes, and which one it is.
  ({String scope, String? queueId, List<LibraryEntry> entries})? _shuffleList;
  String? _shuffleLoading;

  /// Whether shuffle still waits for the list it picks from.
  bool get shuffleLoading => _shuffling && _shuffleLoading != null;

  // The list the playing video shuffles in: the queue it plays from, or its show's episodes.
  String? get _wantedShuffleList {
    final stream = _stream;
    if (stream == null) return null;
    final followed = _followed;
    if (followed != null) return 'queue:${followed.id}';
    final list = _shuffleList;
    // Another episode of the show already listed keeps the list, and the order.
    if (list != null && list.queueId == null && list.entries.any((e) => e.id == stream.id)) return list.scope;
    return 'episodes:${stream.id}';
  }

  void _ensureShuffleList() {
    if (!_shuffling || !inList) return;
    final wanted = _wantedShuffleList;
    if (wanted == null || wanted == _shuffleList?.scope || wanted == _shuffleLoading || wanted == _shuffleFailed) return;
    unawaited(_loadShuffleList(wanted));
  }

  Future<void> _loadShuffleList(String wanted) async {
    final stream = _stream;
    if (stream == null) return;
    _shuffleLoading = wanted;
    final queueId = _followed?.id;
    var request = queueId != null ? BrowseRequest(queue: queueId) : BrowseRequest(episodesOf: stream.id);
    final entries = <LibraryEntry>[];
    try {
      // Every page: a long show is listed 40 episodes at a time.
      for (var pages = 0; pages < 200; pages++) {
        final page = LibraryPage.fromJson(await link.ask('browse', request.toJson()));
        entries.addAll(page.entries);
        if (!page.hasMore) break;
        request = request.nextPage();
      }
    } catch (_) {
      // Without the list, Next follows the usual order.
      if (_shuffleLoading == wanted) {
        _shuffleLoading = null;
        _shuffleFailed = wanted;
      }
      notifyListeners();
      return;
    }
    if (_shuffleLoading != wanted) return;
    _shuffleLoading = null;
    // A show's list is named by its first episode, so every episode of it shares one order.
    final scope = queueId != null ? wanted : 'show:${entries.isEmpty ? stream.id : entries.first.id}';
    _shuffleList = (scope: scope, queueId: queueId, entries: entries);
    notifyListeners();
  }

  // The step shuffle takes from the playing video: a random one this round hasn't played, or back to the one before.
  EpisodeStep? _shuffledStep({required bool forward}) {
    final stream = _stream;
    final list = _shuffleList;
    if (stream == null || list == null || _shuffleLoading != null) return null;
    if ((list.queueId != null) != (_followed != null)) return null;
    return shuffledStep(_shuffleOrder, scope: list.scope, entries: list.entries, inQueue: list.queueId != null, current: stream.id,
        place: stream.queue?.index, loop: loopMode == 'all', forward: forward);
  }

  /// Shuffle's step from [current] in [entries], a queue's videos or a show's episodes: forward, a random one this round
  /// hasn't played; back, the one that played before. A show shuffles its regular episodes; specials only when there is
  /// nothing else.
  @visibleForTesting
  static EpisodeStep? shuffledStep(ShuffleOrder order, {required String scope, required List<LibraryEntry> entries, required bool inQueue,
      required String current, int? place, required bool loop, required bool forward}) {
    var pool = entries.where((e) => e.playable || e.id == current).toList();
    if (!inQueue) {
      final regular = pool.where((e) => e.season != 0 || e.id == current).toList();
      if (regular.any((e) => e.id != current)) pool = regular;
    }
    final ids = [for (final e in pool) e.id];
    final id = forward ? order.next(scope, current, ids, loop: loop) : order.previous(scope, current, ids);
    if (id == null) return null;
    // A video queued twice plays from a place other than the current one.
    final entry = pool.firstWhere((e) => e.id == id && e.index != place, orElse: () => pool.firstWhere((e) => e.id == id));
    return EpisodeStep.ofEntry(entry, inQueue: inQueue);
  }

  // What Previous, Next and up next follow: the queue played from (null: the show's episodes), and, after the player
  // switched lists, the steps worked out from that list here.
  QueueRef? _followed;
  ({EpisodeStep? previous, EpisodeStep? next, EpisodeStep? first})? _listSteps;

  /// The saved queue Previous and Next follow, or null for the show's episodes.
  QueueRef? get followed => _followed;

  /// Follows [entries], a queue's videos ([queue]) or the show's episodes (null), from now on, as the PC's player does
  /// when another list is chosen: the video carries on, Previous and Next step through the list from its place, and in
  /// a queue that doesn't have it, Next starts the queue from its first video.
  void followList(QueueRef? queue, List<LibraryEntry> entries) {
    final stream = _stream;
    if (stream == null) return;
    _followed = queue;
    _listSteps = stepsIn(entries, stream.id, queue == null ? null : (queue.id == stream.queue?.id ? stream.queue?.index : null), inQueue: queue != null);
    _ensureShuffleList();
    notifyListeners();
  }

  /// Previous, Next and Loop all's start in a list, from the video [id] (at [place] when it is there twice).
  @visibleForTesting
  static ({EpisodeStep? previous, EpisodeStep? next, EpisodeStep? first}) stepsIn(List<LibraryEntry> entries, String id, int? place, {required bool inQueue}) {
    var at = place == null ? -1 : entries.indexWhere((e) => e.id == id && e.index == place);
    if (at < 0) at = entries.indexWhere((e) => e.id == id);
    EpisodeStep step(LibraryEntry entry) => EpisodeStep.ofEntry(entry, inQueue: inQueue);
    if (at < 0) {
      // A queue without the video starts from its first one, as on the PC; a show's list without it has nothing to step to.
      final start = inQueue ? entries.where((e) => e.playable).firstOrNull : null;
      return (previous: null, next: start == null ? null : step(start), first: null);
    }
    LibraryEntry? previous, next, first;
    for (var i = at - 1; i >= 0 && previous == null; i--) {
      if (entries[i].playable) previous = entries[i];
    }
    for (var i = at + 1; i < entries.length && next == null; i++) {
      if (entries[i].playable) next = entries[i];
    }
    if (next == null) {
      for (var i = 0; i < entries.length && first == null; i++) {
        if (i != at && entries[i].playable) first = entries[i];
      }
    }
    return (previous: previous == null ? null : step(previous), next: next == null ? null : step(next), first: first == null ? null : step(first));
  }

  /// Plays a listed video: from a queue ([queue]) or the show's episodes. The player follows that list once the video
  /// has started, from the PC's answer, so a video that can't be had leaves the list it followed as it was.
  Future<bool> playListed(LibraryEntry entry, QueueRef? queue) async {
    final step = EpisodeStep.ofEntry(entry, inQueue: queue != null);
    if (pending.value?.episode?.id == step.id) return false;
    return watch(step.id, quality: _chosenQuality, step: step, queue: queue?.at(entry.index));
  }

  /// Whether Previous goes back to the start of this video rather than to the episode before: once it has played more
  /// than 3 seconds, or after it ended, as on the PC.
  bool get previousRestarts {
    final player = _player;
    if (player == null || _stream == null) return false;
    return _ended || _positionOf(player) > 3000;
  }

  /// Previous: back to the start of this video, or near the start, the episode before it.
  Future<void> previous() async {
    final player = _player;
    if (player == null) return;
    if (previousRestarts || previousEpisode == null) {
      _endUpNext();
      _ended = false;
      await player.seek(Duration.zero);
      await player.play();
      return;
    }
    final back = previousEpisode!;
    // Already on its way: a second press waits for it, and leaves its step back marked.
    if (pending.value?.episode?.id == back.id) return;
    // Back with Shuffle retraces what played.
    if (_shuffleReady) _shuffleOrder.goingBack(back.id);
    // Refused: a later pick of that video by hand is a new step, not this one back.
    if (!await playEpisode(back)) _shuffleOrder.goingBack(null);
  }

  /// Next: the episode after this one.
  Future<void> next() async {
    final step = nextEpisode;
    if (step != null) await playEpisode(step);
  }

  /// Plays another episode on the same player, at the quality chosen in this viewing.
  Future<bool> playEpisode(EpisodeStep step) async {
    if (pending.value?.episode?.id == step.id) return false;
    final followed = _followed;
    return watch(step.id, quality: _chosenQuality, step: step, queue: followed != null && step.queueIndex != null ? followed.at(step.queueIndex) : null);
  }

  /// The next episode, offered when this one ends.
  final ValueNotifier<UpNextOffer?> upNext = ValueNotifier(null);
  Timer? _upNextTimer;

  void _videoEnded() {
    final stream = _stream;
    final player = _player;
    if (stream == null || player == null) return;
    final (replay, step) = afterEnd(loopMode, nextEpisode, _firstEpisode);
    if (replay) {
      unawaited(_replay());
      return;
    }
    if (step == null) return;
    final offer = UpNextOffer(step: step, deadline: DateTime.now().add(upNextLength), length: upNextLength);
    upNext.value = offer;
    _upNextTimer?.cancel();
    _upNextTimer = Timer(upNextLength, () {
      if (identical(upNext.value, offer)) unawaited(playUpNext());
    });
  }

  /// What follows the end of [stream], as on the PC: Loop one replays it; otherwise the next episode is offered, or with
  /// Loop all the show's first; Loop all with nothing else to play replays it.
  @visibleForTesting
  static (bool replay, EpisodeStep? offer) afterEnd(String loopMode, EpisodeStep? next, EpisodeStep? first) {
    if (loopMode == 'one') return (true, null);
    final step = next ?? (loopMode == 'all' ? first : null);
    if (step == null) return (loopMode == 'all', null);
    return (false, step);
  }

  Future<void> _replay() async {
    final player = _player;
    if (player == null) return;
    _ended = false;
    await player.seek(Duration.zero);
    await player.play();
  }

  /// Plays the offered episode now.
  Future<void> playUpNext() async {
    final offer = upNext.value;
    _endUpNext();
    if (offer != null) await playEpisode(offer.step);
  }

  /// Stays on this episode.
  void cancelUpNext() => _endUpNext();

  void _endUpNext() {
    _upNextTimer?.cancel();
    _upNextTimer = null;
    upNext.value = null;
  }

  // ---- Tracks ----

  // What the user chose for this video, kept across another quality or a recovery of it: a language and title for
  // audio, and for subtitles also "off".
  // [index]: the track's place among the file's audio tracks, from 0, as the PC and libmpv both order them.
  ({String? language, String? title, int? index})? _chosenAudio;
  ({bool off, String? language, String? title})? _chosenSubtitle;
  bool _tracksApplied = false;
  String? _defaultSubtitle;

  static List<AudioTrack> audioChoices(Tracks tracks) => tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
  static List<SubtitleTrack> subtitleChoices(Tracks tracks) => tracks.subtitle.where((t) => t.id != 'auto' && t.id != 'no').toList();

  /// The audio tracks to offer: the file's, as the player lists them, or for a conversion, the file's as the PC lists
  /// them, of which the conversion carries one. Ids of a conversion's tracks count from 1, as libmpv's do.
  List<AudioTrack> get audioTracks {
    final listed = _convertedAudio;
    if (listed != null) return listed;
    return audioChoices(_tracks);
  }

  // A conversion's tracks as the PC lists them; null for the file itself and from PCs that don't list them.
  List<AudioTrack>? get _convertedAudio {
    final stream = _stream;
    final source = stream?.sourceAudio;
    if (stream == null || !stream.hls || source == null) return null;
    return [for (final a in source) AudioTrack('${a.index + 1}', a.title, a.language, codec: a.codec, channels: a.layout)];
  }

  /// The audio and subtitle tracks playing now, by id; a null subtitle is none. media_kit reports `auto` until a track
  /// is chosen, so libmpv itself is asked.
  Future<({String? audio, String? subtitle})> selectedTracks() async {
    final player = _player;
    if (player == null) return (audio: null, subtitle: null);
    String? audio = player.state.track.audio.id, subtitle = player.state.track.subtitle.id;
    final native = player.platform;
    if (native is NativePlayer) {
      try {
        audio = await native.getProperty('aid');
        subtitle = await native.getProperty('sid');
      } catch (_) {}
    }
    String? id(String? value) => value == null || value == 'no' || value == 'auto' || value.isEmpty ? null : value;
    // A conversion carries one of the file's tracks: the one the PC converted with.
    final stream = _stream;
    if (_convertedAudio != null) return (audio: stream!.audioTrack == null ? null : '${stream.audioTrack! + 1}', subtitle: id(subtitle));
    return (audio: id(audio), subtitle: id(subtitle));
  }

  // Which of the file's audio tracks plays now, counted from 0 as the PC counts them: the one a conversion carries, or
  // the file's track libmpv plays, once picked by hand (otherwise the PC's preferences pick the same one again).
  Future<int?> _playingAudioIndex() async {
    final stream = _stream;
    if (stream == null) return null;
    if (_convertedAudio != null) return stream.audioTrack;
    if (stream.hls || _chosenAudio == null) return null;
    final playing = (await selectedTracks()).audio;
    final at = audioChoices(_tracks).indexWhere((t) => t.id == playing);
    return at < 0 ? null : at;
  }

  /// The user picked an audio track. Subtitles not picked by hand follow the PC's rule for its language, as on the PC.
  /// A conversion carries one track, so the PC converts the video again with the one picked, from where it is.
  Future<void> chooseAudio(AudioTrack track) async {
    final player = _player;
    if (player == null) return;
    final stream = _stream;
    if (pending.value?.episode != null) return;
    // Another quality on its way carries the track playing when it was asked for: a pick now would be lost.
    void waitForQuality(String quality) => _say('Wait for the switch to ${qualityLabel(quality)} to finish, then pick the audio.');
    if (_convertedAudio != null && stream != null) {
      final index = int.tryParse(track.id);
      final pendingAudio = pending.value?.audio;
      if (index == null) return;
      if (pendingAudio == track.id || pendingAudio == null && index - 1 == stream.audioTrack) return;
      if (pending.value?.quality case final quality?) return waitForQuality(quality);
      final labels = audioLabels(audioTracks);
      final at = audioTracks.indexWhere((t) => t.id == track.id);
      _setPending(PendingSwitch.audio(track.id, at < 0 ? 'another audio track' : '${labels[at].name} audio'));
      final position = _stalledAt ?? _positionOf(player);
      if (await watch(stream.id, quality: stream.quality, startAt: position, audio: index - 1)) {
        // Kept for the file itself, should the user switch to it; a refused switch leaves the track playing as it was.
        _chosenAudio = (language: TrackLanguages.languageOf(track.language, track.title), title: track.title, index: index - 1);
      } else if (pending.value?.audio == track.id) {
        _setPending(null);
      }
      return;
    }
    if (pending.value?.quality case final quality?) {
      if (track.id != (await selectedTracks()).audio) waitForQuality(quality);
      return;
    }
    final at = audioChoices(_tracks).indexWhere((t) => t.id == track.id);
    _chosenAudio = (language: TrackLanguages.languageOf(track.language, track.title), title: track.title, index: at < 0 ? null : at);
    await player.setAudioTrack(track);
    if (_chosenSubtitle == null) await _applySubtitlePreference(TrackLanguages.languageOf(track.language, track.title), restoreDefault: true);
    notifyListeners();
  }

  /// The user picked subtitles, or none ([track] null).
  Future<void> chooseSubtitle(SubtitleTrack? track) async {
    final player = _player;
    if (player == null) return;
    _chosenSubtitle = track == null
        ? (off: true, language: null, title: null)
        : (off: false, language: TrackLanguages.languageOf(track.language, track.title), title: track.title);
    await player.setSubtitleTrack(track ?? SubtitleTrack.no());
    notifyListeners();
  }

  // Once a video's tracks are known: the user's choices for it, or else the PC's preferences.
  Future<void> _applyTrackPreferences() async {
    final player = _player;
    final stream = _stream;
    if (player == null || stream == null || _tracksApplied || _switching) return;
    final audio = audioChoices(_tracks);
    if (audio.isEmpty) return;
    _tracksApplied = true;
    // A conversion carries the one track the PC converted with, and no subtitles: there is nothing to pick here.
    if (_convertedAudio != null) return;
    final selected = await selectedTracks();
    _defaultSubtitle = selected.subtitle;
    String? language(AudioTrack t) => TrackLanguages.languageOf(t.language, t.title);
    AudioTrack? pick;
    final chosen = _chosenAudio;
    if (chosen != null) {
      // A choice belongs to this video, whose file lists its tracks in the same order every time: the place picked is
      // the track, whatever language libmpv gives it (one the PC identified is untagged to libmpv).
      final place = chosen.index;
      pick = (place != null && place < audio.length ? audio[place] : null) ??
          audio.where((t) => language(t) == chosen.language && t.title == chosen.title).firstOrNull ??
          audio.where((t) => language(t) == chosen.language).firstOrNull;
    } else {
      pick = TrackLanguages.select(audio, stream.tracks.audio, language, named: (t) => (tag: t.language, title: t.title));
    }
    if (pick != null && pick.id != selected.audio) await player.setAudioTrack(pick);
    final playing = pick ?? audio.where((t) => t.id == selected.audio).firstOrNull;
    final subtitle = _chosenSubtitle;
    if (subtitle != null) {
      final tracks = subtitleChoices(_tracks);
      String? subtitleLanguage(SubtitleTrack t) => TrackLanguages.languageOf(t.language, t.title);
      final match = subtitle.off
          ? SubtitleTrack.no()
          : tracks.where((t) => subtitleLanguage(t) == subtitle.language && t.title == subtitle.title).firstOrNull ??
              tracks.where((t) => subtitleLanguage(t) == subtitle.language).firstOrNull;
      if (match != null) await player.setSubtitleTrack(match);
    } else {
      await _applySubtitlePreference(playing == null ? null : language(playing));
    }
    notifyListeners();
  }

  // The PC's subtitle priorities for audio in [audioLanguage]; with none that matches, the video's own default when
  // [restoreDefault] (after another audio track was picked), or else what libmpv chose.
  Future<void> _applySubtitlePreference(String? audioLanguage, {bool restoreDefault = false}) async {
    final player = _player;
    final stream = _stream;
    if (player == null || stream == null) return;
    final tracks = subtitleChoices(_tracks);
    final preferences = TrackLanguages.subtitlePreferences(audioLanguage, stream.tracks);
    final off = SubtitleTrack.no();
    final match = TrackLanguages.select<SubtitleTrack>(tracks, preferences, (t) => TrackLanguages.languageOf(t.language, t.title), off: off, named: (t) => (tag: t.language, title: t.title));
    if (match != null) {
      await player.setSubtitleTrack(match);
    } else if (restoreDefault) {
      final fallback = tracks.where((t) => t.id == _defaultSubtitle).firstOrNull;
      await player.setSubtitleTrack(fallback ?? off);
    }
  }

  /// Tells the PC how far the phone got. [final_]: the last report of this viewing.
  Future<void> _report({bool final_ = false}) async {
    final stream = _stream;
    final player = _player;
    if (stream == null || player == null || _stalledAt != null || !_positionKnown) return;
    // While the next episode opens, the last one has had its final report; nothing it does now replaces that.
    if (!final_ && pending.value?.episode != null) return;
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
    _endUpNext();
    await player.pause();
    // While stalled, where the video stopped: a stopped player may have gone back to 0:00.
    final position = _stalledAt ?? _positionOf(player);
    await _report(final_: true);
    try {
      if (!link.status.isConnected) await _whenConnected(const Duration(seconds: 20));
      // Left while it waited.
      if (!identical(_stream, stream)) return null;
      // The PC ends this stream before it answers: the reads that then fail are no stall to recover from (that asked the
      // PC for the video again, and it started converting it for nobody).
      _handedOver = true;
      await link.ask('play', {'id': stream.id, 'positionMs': position}, timeout: const Duration(seconds: 30));
    } on RemoteRequestException catch (e) {
      _handedOver = false;
      return e.message;
    }
    return null;
  }

  bool _handedOver = false;

  /// Stops playing on the phone, saving where it got to. Call it once the player is off screen: libmpv's picture
  /// must not be in use when it goes. With [viewing], only that viewing stops; a newer one plays on.
  Future<void> stop({int? viewing}) async {
    if (viewing != null && viewing != _viewing) return;
    _resumeOnReturn = false;
    // A stall in progress: the PC keeps the position it last heard, not the stalled player's.
    final stalled = _stalledAt != null;
    _endRecovery();
    _endsAt = null;
    _opening++;
    _recoveries.clear();
    // The PC plays it now and keeps its own position.
    if (!_handedOver && !stalled) await _report(final_: true);
    _handedOver = false;
    _endUpNext();
    _setPending(null, notify: false);
    _switching = false;
    _chosenQuality = null;
    _chosenAudio = null;
    _chosenSubtitle = null;
    _followed = null;
    _listSteps = null;
    final previous = _detachPlayer();
    if (_stream != null) link.tell('stream-stop', {});
    _stream = null;
    _phase = PhonePlaybackPhase.idle;
    _error = null;
    notifyListeners();
    if (previous != null) await _release(previous);
  }

  // Whether the video was playing when the app went to the background, to carry on when it comes back.
  bool _resumeOnReturn = false;
  bool _inBackground = false;

  /// The app went to the background (and not to a small picture-in-picture window): the video waits, and the PC
  /// learns where it is.
  Future<void> background() async {
    // Already in the background (a second call, as when the background setting is turned off while the app is away):
    // what was playing then is still what to resume.
    if (_inBackground) return;
    _inBackground = true;
    final player = _player;
    if (player == null) {
      // Still opening: it starts paused, and plays when the app is back.
      _resumeOnReturn = _phase == PhonePlaybackPhase.opening;
      return;
    }
    _resumeOnReturn = player.state.playing || _phase == PhonePlaybackPhase.opening;
    if (player.state.playing) await player.pause();
    await _report(final_: true);
  }

  /// The app is back: a video that was playing carries on.
  Future<void> foreground() async {
    _inBackground = false;
    // A stall that waited in the background starts recovering now.
    if (_stalledAt != null) unawaited(_recover());
    // Once only: a video still opening plays as it opens now, and a later return to the app (the notification shade
    // closing counts) doesn't start a video the user paused since.
    final resume = _resumeOnReturn;
    _resumeOnReturn = false;
    final player = _player;
    if (resume && player != null) await player.play();
  }

  /// The picture-in-picture window is on screen (again, after the screen was off, or its button was used): the app
  /// isn't in the background, and what the user does in the window stands; nothing resumes later on its own.
  void pictureInPictureShown() {
    _inBackground = false;
    // A stall that waited in the background starts recovering now.
    if (_stalledAt != null) unawaited(_recover());
    _resumeOnReturn = false;
  }

  @visibleForTesting
  bool get resumesOnReturn => _resumeOnReturn;

  /// Debug previews and tests only: shows [player], already opening a video of its own (or none), as this viewing's
  /// [stream].
  void debugShow(Player? player, StreamInfo stream) {
    _player = player;
    if (player != null) _listen(player);
    _stream = stream;
    _phase = PhonePlaybackPhase.playing;
    notifyListeners();
  }
  @visibleForTesting
  bool get inBackground => _inBackground;

  /// The small picture-in-picture window was closed: the video stops, and stays stopped when the app opens again.
  Future<void> pictureInPictureClosed() async {
    _resumeOnReturn = false;
    // Nor does the next episode start on its own: its countdown ran on while the app was away.
    _endUpNext();
    final player = _player;
    if (player == null) return;
    if (player.state.playing) await player.pause();
    await _report(final_: true);
  }

  void _fail(String message) {
    _resumeOnReturn = false;
    _switching = false;
    _endUpNext();
    pending.value = null;
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
    _upNextTimer?.cancel();
    notice.dispose();
    pending.dispose();
    upNext.dispose();
    super.dispose();
  }
}
