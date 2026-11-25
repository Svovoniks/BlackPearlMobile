import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the PC plays, for Android's media controls: the lock screen and the notification show it with a timeline and
/// play buttons, and headset buttons work it.
@immutable
class NowPlaying {
  const NowPlaying({required this.title, this.detail = '', required this.playing, this.positionMs = 0, this.durationMs = 0, this.hasNext = false, this.volume});
  final String title;
  final String detail;
  final bool playing;

  /// Where the video is now; Android moves its timeline on from here while it plays.
  final int positionMs;
  final int durationMs;
  final bool hasNext;

  /// The PC's volume, 0 to 100, when the phone's volume buttons set it while the PC plays; null leaves them the
  /// phone's own.
  final int? volume;

  Map<String, Object?> toMap() => {
    'title': title,
    'detail': detail,
    'playing': playing,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'hasNext': hasNext,
    'volume': volume,
  };

  @override
  bool operator ==(Object other) =>
      other is NowPlaying &&
      other.title == title &&
      other.detail == detail &&
      other.playing == playing &&
      other.positionMs == positionMs &&
      other.durationMs == durationMs &&
      other.hasNext == hasNext &&
      other.volume == volume;
  @override
  int get hashCode => Object.hash(title, detail, playing, positionMs, durationMs, hasNext, volume);
}

/// What the background notification shows.
@immutable
class BackgroundNotice {
  const BackgroundNotice({required this.title, required this.text, this.playing, this.media});
  final String title;
  final String text;

  /// Whether the PC is playing, for the notification's Play/Pause button; null hides it.
  final bool? playing;

  /// The PC's video, which makes the notification a media one; null leaves it plain.
  final NowPlaying? media;

  Map<String, Object?> toMap() => {'title': title, 'text': text, 'playing': playing, 'media': media?.toMap()};

  @override
  bool operator ==(Object other) => other is BackgroundNotice && other.title == title && other.text == text && other.playing == playing && other.media == media;
  @override
  int get hashCode => Object.hash(title, text, playing, media);
}

/// A button of the notification or of Android's media controls: `toggle`, `play`, `pause`, `next`, `previous` and
/// `disconnect`, and with a value `seek-by` and `seek-to` (milliseconds) and `volume` (0 to 100).
typedef BackgroundAction = void Function(String action, [int? value]);

/// The Android foreground service that keeps the app, and its link to the PC, running after the app is closed. Android
/// shows its notification while it runs; the notification's Disconnect button stops it
/// until the app is opened again.
class BackgroundLink {
  BackgroundLink({MethodChannel? channel, MethodChannel? notifications})
    : _channel = channel ?? const MethodChannel('blackpearl/background'),
      _notifications = notifications ?? const MethodChannel('blackpearl/notifications');

  final MethodChannel _channel;
  final MethodChannel _notifications;

  /// Only Android has it.
  static bool get supported => !kIsWeb && Platform.isAndroid;

  bool _running = false;
  bool get running => _running;
  BackgroundNotice? _shown;

  // Android starts the service again by itself after it stopped the app (it is sticky), and the app with it, which then
  // never asked for it. Until this side has started or stopped it, it may be running.
  bool _settled = false;
  bool get mayBeRunning => _running || !_settled;

  /// Called with what was pressed on the notification or in the media controls (see [BackgroundAction]).
  void listen(BackgroundAction onAction) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'action') return null;
      final pressed = call.arguments;
      if (pressed is String) {
        onAction(pressed);
      } else if (pressed is Map && pressed['action'] is String) {
        final value = pressed['value'];
        onAction(pressed['action'] as String, value is num ? value.round() : null);
      }
      return null;
    });
  }

  /// Starts the service, or updates its notification. Android refuses to start it while the app is in the background;
  /// that returns false.
  Future<bool> show(BackgroundNotice notice) async {
    if (_running && notice == _shown) return true;
    try {
      final started = await _channel.invokeMethod<bool>(_running ? 'update' : 'start', notice.toMap()) ?? false;
      _running = started;
      _settled = true;
      _shown = started ? notice : null;
      return started;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> stop() async {
    _running = false;
    _settled = true;
    _shown = null;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // Already stopped.
    } on MissingPluginException {
      // Not on this platform.
    }
  }

  /// Keeps the processor and Wi-Fi awake while the phone plays the PC's sound with its screen off, or lets them sleep.
  Future<void> keepAwake(bool hold) async {
    try {
      await _channel.invokeMethod<void>('keepAwake', hold);
    } on PlatformException {
      // Without the locks the sound may stutter with the screen off; it still plays.
    } on MissingPluginException {
      // Not on this platform.
    }
  }

  /// Asks for permission to show notifications (Android 13 and later), once.
  Future<void> askForNotifications() async {
    try {
      await _notifications.invokeMethod<void>('request');
    } on PlatformException {
      // No window to ask in.
    } on MissingPluginException {
      // Not on this platform.
    }
  }
}
