import 'dart:async';

import 'package:flutter/foundation.dart';

import 'background/background_link.dart';
import 'connection/remote_connection.dart';
import 'connection/remote_link.dart';
import 'connection/transport.dart';
import 'playback/phone_playback.dart';
import 'playback/phone_sound.dart';
import 'protocol/pair_link.dart';
import 'storage/app_settings.dart';
import 'storage/paired_pcs.dart';

typedef ConnectionFactory = RemoteConnection Function(
  LinkTarget target, {
  void Function(PairedPc pc)? onPaired,
  void Function(String pcId, String name)? onPcName,
});

/// The app's state: the paired PCs, which one the remote is using, its connection, the phone's own player, and the
/// background service that keeps the connection while the app is closed.
class AppModel extends ChangeNotifier {
  AppModel({required this.store, required this.connect, AppSettings? settings, this.background, this.createPlayback, this.createSound})
    : settings = settings ?? AppSettings(MemorySettingsStore()) {
    this.settings.addListener(_settingsChanged);
    background?.listen(_backgroundAction);
  }

  final PairedPcStore store;
  final ConnectionFactory connect;
  final AppSettings settings;

  /// The Android foreground service; null where there is none.
  final BackgroundLink? background;

  /// Makes the phone's player for a connection; null leaves the phone without one (tests).
  final PhonePlayback Function(RemoteConnection connection)? createPlayback;

  PhonePlayback? _playback;
  PhonePlayback? get playback => _playback;

  /// Makes Sound on the phone for a connection; null leaves the phone without it (tests).
  final PhoneSound Function(RemoteConnection connection, AppSettings settings, BackgroundLink? background)? createSound;
  PhoneSound? _sound;
  PhoneSound? get sound => _sound;
  bool _foreground = true;

  List<PairedPc> _pcs = [];
  List<PairedPc> get pcs => List.unmodifiable(_pcs);

  RemoteConnection? _connection;
  RemoteConnection? get connection => _connection;

  bool _loaded = false;
  bool get loaded => _loaded;

  /// Set when the paired PCs couldn't be read; [load] tries again.
  String? _loadError;
  String? get loadError => _loadError;
  bool _loading = false;
  bool get loading => _loading;

  /// A short message about a save that failed, for a snack bar.
  final ValueNotifier<String?> notice = ValueNotifier(null);

  /// Showing the pairing screen even though PCs are paired ("Pair another PC", or a failed code).
  bool _pairingRequested = false;
  bool get showPairing => _loaded && (_pcs.isEmpty && _connection == null || _pairingRequested);

  String? _pairingError;
  String? get pairingError => _pairingError;

  Timer? _backgroundTimer;

  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    notifyListeners();
    try {
      _pcs = await store.load();
    } catch (_) {
      _loading = false;
      _loadError = "This phone's secure storage didn't open, so the paired PCs can't be read.";
      notifyListeners();
      return;
    }
    String? last;
    try {
      last = await store.lastUsed();
    } catch (_) {}
    _loading = false;
    _loadError = null;
    _loaded = true;
    final pc = _pcs.where((p) => p.pcId == last).firstOrNull ?? _pcs.firstOrNull;
    if (pc != null && _connection == null) _use(LinkTarget.paired(pc));
    // A service Android started again by itself is stopped here when nothing needs it.
    _syncBackground();
    notifyListeners();
  }

  String? get currentPcId => _connection?.target.isPairing == true ? null : _connection?.target.pcId;

  void select(PairedPc pc) {
    _pairingRequested = false;
    _pairingError = null;
    unawaited(_quietly(store.setLastUsed(pc.pcId)));
    _use(LinkTarget.paired(pc));
    notifyListeners();
  }

  /// Starts pairing with a scanned or pasted link (or one the system opened the app with). The PC in use stays
  /// connected meanwhile: a code that doesn't work (used, expired, replaced, or its server out of reach) brings it back,
  /// with the pairing screen saying why.
  void pair(PairLink link) {
    _pairingRequested = false;
    _pairingError = null;
    _use(LinkTarget.pairing(link), hold: true);
    notifyListeners();
  }

  // The working link to the PC in use, kept while a pairing code is tried.
  RemoteConnection? _held;

  void _pairingChanged() {
    final trial = _connection;
    final held = _held;
    if (trial == null || held == null || !trial.target.isPairing || trial.status.phase != LinkPhase.failed) return;
    final message = trial.status.message;
    // Not from inside the failing connection's own notification.
    scheduleMicrotask(() {
      if (!identical(_connection, trial) || !identical(_held, held)) return;
      _held = null;
      _disposeConnection(sync: false);
      _adopt(held);
      requestPairing(error: message);
    });
  }

  void requestPairing({String? error}) {
    _pairingRequested = true;
    _pairingError = error;
    notifyListeners();
  }

  void cancelPairing() {
    _pairingRequested = false;
    _pairingError = null;
    notifyListeners();
  }

  Future<void> forget(PairedPc pc) async {
    _pcs = _pcs.where((p) => p.pcId != pc.pcId).toList();
    final saved = _save("Couldn't save on this phone. ${pc.name} will be back the next time the app starts.");
    if (_connection?.target.pcId == pc.pcId) {
      final next = _pcs.firstOrNull;
      // Straight to the next PC: the service carries on with it rather than stopping and starting at once.
      if (next != null) {
        _use(LinkTarget.paired(next));
      } else {
        _disposeConnection();
      }
      await _quietly(store.setLastUsed(next?.pcId));
    }
    await saved;
    notifyListeners();
  }

  /// Connects to [target]. [hold]: a pairing code is tried, and the working link it replaces is kept until it pairs.
  void _use(LinkTarget target, {bool hold = false}) {
    // The service is set for the new link once, rather than stopped for the old one and started again in the same turn.
    _disposeConnection(hold: hold && target.isPairing, sync: false);
    _adopt(connect(target, onPaired: _paired, onPcName: _renamed), start: true);
  }

  void _adopt(RemoteConnection connection, {bool start = false}) {
    _connection = connection;
    _playback = createPlayback?.call(connection)?..awayQuality = settings.awayQuality;
    _playback?.addListener(_playbackChanged);
    _sound = createSound?.call(connection, settings, background)?..addListener(_soundChanged);
    connection.addListener(_syncBackground);
    connection.addListener(_pairingChanged);
    if (start) connection.start();
    _syncBackground();
  }

  void _disposeConnection({bool hold = false, bool sync = true}) {
    final connection = _connection;
    connection?.removeListener(_syncBackground);
    connection?.removeListener(_pairingChanged);
    // Before the connection goes: it tells the PC to play its sound again.
    _sound?.removeListener(_soundChanged);
    _sound?.dispose();
    _sound = null;
    _playback?.removeListener(_playbackChanged);
    _playback?.dispose();
    _playback = null;
    _connection = null;
    if (hold && connection != null && !connection.target.isPairing) {
      // Kept as it is, connected or trying, in case the code doesn't work.
      _held?.dispose();
      _held = connection;
    } else {
      connection?.dispose();
      if (!hold) {
        _held?.dispose();
        _held = null;
      }
    }
    if (sync) _syncBackground();
  }

  // ---- the background service ----

  /// A stopped connection (the notification's Disconnect, or the app closed without the service) needs no service; it
  /// comes back with the connection when the app is opened again. While the phone plays the PC's sound the service runs
  /// even with the setting off: without it the sound would stop soon after the screen turns off.
  /// A connection halted by a failure only the user can fix (the phone was removed from the PC, say) needs none either:
  /// it tries nothing more until the app is opened. While a pairing code is tried, the PC in use keeps it.
  RemoteConnection? get _linkKept => _held ?? (_connection?.target.isPairing == false ? _connection : null);
  bool get _keepsLink =>
      background != null &&
      (settings.backgroundLink || (_sound?.on ?? false)) &&
      _linkKept != null &&
      _linkKept!.running &&
      !_linkKept!.halted;

  void _soundChanged() {
    _syncBackground();
    // The sound kept the link up in the background with the setting off; once it stops, the link goes as it would have.
    if (!_foreground && !settings.backgroundLink && !(_sound?.on ?? false) && _backgroundTimer == null) paused();
  }

  // Watching a video on the phone plays its own sound: the PC's goes back to the PC.
  void _playbackChanged() {
    if ((_playback?.active ?? false) && (_sound?.on ?? false)) {
      unawaited(_sound!.turnOff(message: 'The sound went back to the PC while this phone plays a video.'));
    }
  }

  void _settingsChanged() {
    _playback?.awayQuality = settings.awayQuality;
    _syncBackground();
    // Turned off while the app isn't showing: let the link go, as it would have without the service.
    if (!settings.backgroundLink && !_foreground && !(_sound?.on ?? false)) paused();
    notifyListeners();
  }

  /// Starts, updates or stops the service to match the setting and the link.
  void _syncBackground() {
    final service = background;
    if (service == null) return;
    if (!_keepsLink) {
      // Also one Android started again by itself after it stopped the app, which this side never started; only once the
      // paired PCs are read, though, as a link to one of them may want it.
      if (service.running || service.mayBeRunning && _loaded) unawaited(service.stop());
      return;
    }
    // Android starts a foreground service only while the app is showing; one already running can be updated any time.
    if (!service.running && !_foreground) return;
    final connection = _linkKept!;
    final state = connection.state;
    final status = connection.status;
    final String text;
    bool? playing;
    if (status.isConnected) {
      if (state != null && state.media && (_sound?.on ?? false)) {
        text = '${state.title.isEmpty ? 'Video' : state.title} · sound on this phone';
        if (state.canControl) playing = state.playing;
      } else if (state != null && state.media) {
        text = '${state.title.isEmpty ? 'Video' : state.title} · ${state.playing ? 'playing' : 'paused'} on the PC';
        if (state.canControl) playing = state.playing;
      } else {
        text = 'Connected. Nothing is playing on the PC.';
      }
    } else if (status.phase == LinkPhase.waitingForPc) {
      text = "Waiting for the PC to come online";
    } else {
      text = 'Reconnecting to the PC';
    }
    final first = !service.running;
    unawaited(service.show(BackgroundNotice(title: connection.pcName, text: text, playing: playing)).then((started) {
      if (started && first && !settings.askedNotifications) {
        unawaited(settings.markAskedNotifications());
        unawaited(service.askForNotifications());
      }
    }));
  }

  void _backgroundAction(String action) {
    switch (action) {
      case 'toggle':
        _connection?.command('toggle');
      case 'disconnect':
        // Drops the link now and leaves the setting alone. The service stops as the connection does.
        _backgroundTimer?.cancel();
        _backgroundTimer = null;
        // A connection halted by a failure says nothing when it stops, so look again once it has.
        unawaited(_connection?.stop().then((_) => _syncBackground()));
    }
  }

  void _paired(PairedPc pc) {
    // The code worked: the link to the PC used until now goes.
    _held?.dispose();
    _held = null;
    _pcs = [..._pcs.where((p) => p.pcId != pc.pcId), pc];
    unawaited(_save("Paired with ${pc.name}, but this phone couldn't save it. The remote works until the app closes; then pair again."));
    unawaited(_quietly(store.setLastUsed(pc.pcId)));
    notifyListeners();
  }

  void _renamed(String pcId, String name) {
    final index = _pcs.indexWhere((p) => p.pcId == pcId);
    if (index < 0) return;
    _pcs = [..._pcs]..[index] = _pcs[index].withName(name);
    // The new name comes again on the next connection; a failed save here isn't worth a message.
    unawaited(_quietly(_write()));
    notifyListeners();
  }

  /// Writes the paired PCs. While the stored list couldn't be read, nothing is written: the list in memory then holds only
  /// what was paired since, and writing it would replace the PCs still on the phone.
  Future<void> _write() {
    if (!_loaded || _loadError != null) return Future.error(StateError('The paired PCs were not read'));
    return store.save(_pcs);
  }

  /// Saves the paired PCs, and reports [failure] if that fails.
  Future<void> _save(String failure) async {
    try {
      await _write();
    } catch (_) {
      notice.value = null;
      notice.value = failure;
    }
  }

  /// Which PC was used last only picks the one to open next time; losing it is harmless.
  static Future<void> _quietly(Future<void> future) => future.catchError((Object _) {});

  // ---- app lifecycle and network ----

  /// The app went to the background: the phone's video pauses. With the background service the link stays;
  /// without it, it stays a little while (a quick look at another app), then goes.
  void paused() {
    _foreground = false;
    unawaited(_playback?.background());
    _backgroundTimer?.cancel();
    _backgroundTimer = null;
    if (_keepsLink && (background?.running ?? false)) return;
    _backgroundTimer = Timer(const Duration(seconds: 30), () => unawaited(_connection?.stop()));
  }

  void resumed() {
    _foreground = true;
    _backgroundTimer?.cancel();
    _backgroundTimer = null;
    _connection?.resume();
    unawaited(_playback?.foreground());
    _syncBackground();
  }

  void networkChanged() => _connection?.networkChanged();

  @override
  void dispose() {
    _backgroundTimer?.cancel();
    settings.removeListener(_settingsChanged);
    _disposeConnection();
    notice.dispose();
    super.dispose();
  }
}

/// Describes the path for the chooser.
String describePath(NetworkPath path) => switch (path) {
  NetworkPath.home => 'Connected on your home network',
  NetworkPath.away => 'Connected over the internet',
  NetworkPath.relayed => 'Connected over the internet, through the relay',
  NetworkPath.unknown => 'Connected',
};
