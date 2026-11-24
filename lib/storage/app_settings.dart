import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the app's own settings are kept; the real one is the platform's preferences.
abstract class SettingsStore {
  Future<bool?> readBool(String key);
  Future<String?> readString(String key);
  Future<void> writeBool(String key, bool value);
  Future<void> writeString(String key, String value);
}

class PreferencesSettingsStore implements SettingsStore {
  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();
  @override
  Future<bool?> readBool(String key) => _preferences.getBool(key);
  @override
  Future<String?> readString(String key) => _preferences.getString(key);
  @override
  Future<void> writeBool(String key, bool value) => _preferences.setBool(key, value);
  @override
  Future<void> writeString(String key, String value) => _preferences.setString(key, value);
}

class MemorySettingsStore implements SettingsStore {
  final Map<String, Object> values = {};
  @override
  Future<bool?> readBool(String key) async => values[key] as bool?;
  @override
  Future<String?> readString(String key) async => values[key] as String?;
  @override
  Future<void> writeBool(String key, bool value) async => values[key] = value;
  @override
  Future<void> writeString(String key, String value) async => values[key] = value;
}

/// The app's settings: whether it stays connected in the background, and the quality to stream at away from home.
class AppSettings extends ChangeNotifier {
  AppSettings(this._store);
  final SettingsStore _store;

  static const qualities = ['auto', 'original', '1080p', '720p', '480p'];

  bool _backgroundLink = true;
  String _awayQuality = 'auto';
  bool _askedNotifications = false;
  String _loopMode = 'off';
  bool _shuffle = false;
  int _soundDelayMs = 0;
  bool _followPhoneRotation = false;
  bool _crashReports = true;

  /// Whether errors, crashes and how long startup and opening videos take go to BlackPearl's developer through Sentry,
  /// with paths, titles, addresses and names removed. On by default.
  bool get crashReports => _crashReports;

  /// Whether the player turns with the phone, as Android's Auto-rotate says. Off by default: each video opens in its
  /// own shape, sideways for a wide video and upright for a tall one, and keeps it however the phone is held.
  bool get followPhoneRotation => _followPhoneRotation;

  /// How much later than the PC's picture the phone plays the PC's sound, in milliseconds (negative: earlier), for
  /// headphones and speakers that take their own time. Set on the Remote tab while the sound is on the phone.
  int get soundDelayMs => _soundDelayMs;
  static const soundDelayLimitMs = 1000;

  /// The player's Shuffle, as on the PC.
  bool get shuffle => _shuffle;

  static const loopModes = ['off', 'all', 'one'];

  /// The player's Loop, as on the PC: `off`, `all` (a show starts again after its last episode) or `one` (the video
  /// replays).
  String get loopMode => _loopMode;

  /// Keeps the link to the PC up while the app is closed, with a notification that says so. On by default.
  bool get backgroundLink => _backgroundLink;

  /// `auto` streams a 720p conversion away from home and the file itself at home.
  String get awayQuality => _awayQuality;

  /// Whether the app has asked for permission to show its notification.
  bool get askedNotifications => _askedNotifications;

  Future<void> load() async {
    try {
      _backgroundLink = await _store.readBool('backgroundLink') ?? true;
      final quality = await _store.readString('awayQuality');
      _awayQuality = qualities.contains(quality) ? quality! : 'auto';
      _askedNotifications = await _store.readBool('askedNotifications') ?? false;
      final loop = await _store.readString('loopMode');
      _loopMode = loopModes.contains(loop) ? loop! : 'off';
      _shuffle = await _store.readBool('shuffle') ?? false;
      _followPhoneRotation = await _store.readBool('followPhoneRotation') ?? false;
      _crashReports = await _store.readBool('crashReports') ?? true;
      _soundDelayMs = (int.tryParse(await _store.readString('soundDelayMs') ?? '') ?? 0).clamp(-soundDelayLimitMs, soundDelayLimitMs);
    } catch (_) {
      // Unreadable preferences leave the defaults.
    }
    notifyListeners();
  }

  Future<void> setBackgroundLink(bool value) async {
    if (value == _backgroundLink) return;
    _backgroundLink = value;
    notifyListeners();
    await _quietly(_store.writeBool('backgroundLink', value));
  }

  Future<void> setAwayQuality(String value) async {
    if (!qualities.contains(value) || value == _awayQuality) return;
    _awayQuality = value;
    notifyListeners();
    await _quietly(_store.writeString('awayQuality', value));
  }

  Future<void> setLoopMode(String value) async {
    if (!loopModes.contains(value) || value == _loopMode) return;
    _loopMode = value;
    notifyListeners();
    await _quietly(_store.writeString('loopMode', value));
  }

  Future<void> setShuffle(bool value) async {
    if (value == _shuffle) return;
    _shuffle = value;
    notifyListeners();
    await _quietly(_store.writeBool('shuffle', value));
  }

  Future<void> setFollowPhoneRotation(bool value) async {
    if (value == _followPhoneRotation) return;
    _followPhoneRotation = value;
    notifyListeners();
    await _quietly(_store.writeBool('followPhoneRotation', value));
  }

  Future<void> setCrashReports(bool value) async {
    if (value == _crashReports) return;
    _crashReports = value;
    notifyListeners();
    await _quietly(_store.writeBool('crashReports', value));
  }

  Future<void> setSoundDelayMs(int value) async {
    value = value.clamp(-soundDelayLimitMs, soundDelayLimitMs);
    if (value == _soundDelayMs) return;
    _soundDelayMs = value;
    notifyListeners();
    await _quietly(_store.writeString('soundDelayMs', '$value'));
  }

  Future<void> markAskedNotifications() async {
    _askedNotifications = true;
    await _quietly(_store.writeBool('askedNotifications', true));
  }

  static Future<void> _quietly(Future<void> future) => future.catchError((Object _) {});
}
