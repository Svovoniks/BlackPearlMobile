import 'dart:async';

import 'package:flutter/foundation.dart';

import 'background/background_link.dart';
import 'connection/remote_connection.dart';
import 'connection/remote_link.dart';
import 'connection/transport.dart';
import 'playback/phone_playback.dart';
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
  AppModel({required this.store, required this.connect, AppSettings? settings, this.background, this.createPlayback})
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

  /// Starts pairing with a scanned or pasted link (or one the system opened the app with).
  void pair(PairLink link) {
    _pairingRequested = false;
    _pairingError = null;
    _use(LinkTarget.pairing(link));
    notifyListeners();
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
      _disposeConnection();
      final next = _pcs.firstOrNull;
      if (next != null) _use(LinkTarget.paired(next));
      await _quietly(store.setLastUsed(next?.pcId));
    }
    await saved;
    notifyListeners();
  }

  void _use(LinkTarget target) {
    _disposeConnection();
    final connection = connect(target, onPaired: _paired, onPcName: _renamed);
    _connection = connection;
    _playback = createPlayback?.call(connection)?..awayQuality = settings.awayQuality;
    connection.addListener(_syncBackground);
    connection.start();
    _syncBackground();
  }

  void _disposeConnection() {
    _connection?.removeListener(_syncBackground);
    _playback?.dispose();
    _playback = null;
    _connection?.dispose();
    _connection = null;
    _syncBackground();
  }

  // ---- the background service ----

  bool get _keepsLink => background != null && settings.backgroundLink && _connection != null && !_connection!.target.isPairing;

  void _settingsChanged() {
    _playback?.awayQuality = settings.awayQuality;
    _syncBackground();
    // Turned off while the app isn't showing: let the link go, as it would have without the service.
    if (!settings.backgroundLink && !_foreground) paused();
    notifyListeners();
  }

  /// Starts, updates or stops the service to match the setting and the link.
  void _syncBackground() {
    final service = background;
    if (service == null) return;
    if (!_keepsLink) {
      if (service.running) unawaited(service.stop());
      return;
    }
    // Android starts a foreground service only while the app is showing; one already running can be updated any time.
    if (!service.running && !_foreground) return;
    final connection = _connection!;
    final state = connection.state;
    final status = connection.status;
    final String text;
    bool? playing;
    if (status.isConnected) {
      if (state != null && state.media) {
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
      case 'turnOff':
        unawaited(background?.stop());
        unawaited(settings.setBackgroundLink(false));
    }
  }

  void _paired(PairedPc pc) {
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
