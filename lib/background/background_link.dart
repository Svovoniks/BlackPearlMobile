import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the background notification shows.
@immutable
class BackgroundNotice {
  const BackgroundNotice({required this.title, required this.text, this.playing});
  final String title;
  final String text;

  /// Whether the PC is playing, for the notification's Play/Pause button; null hides it.
  final bool? playing;

  Map<String, Object?> toMap() => {'title': title, 'text': text, 'playing': playing};

  @override
  bool operator ==(Object other) => other is BackgroundNotice && other.title == title && other.text == text && other.playing == playing;
  @override
  int get hashCode => Object.hash(title, text, playing);
}

/// The Android foreground service that keeps the app, and its link to the PC, running after the app is closed. Android
/// shows its notification while it runs; the notification's Turn off button stops it.
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

  /// Called with `toggle` (the notification's Play/Pause) and `turnOff`.
  void listen(void Function(String action) onAction) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'action' && call.arguments is String) onAction(call.arguments as String);
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
    _shown = null;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // Already stopped.
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
