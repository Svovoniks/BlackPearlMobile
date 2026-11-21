import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android's picture in picture for the phone's player: the video keeps playing in a small window over other apps.
/// While the player screen wants it, leaving the app (Home, or switching apps) moves the video there by itself; the
/// player's button does it at once. The window has a Play/Pause button.
class PictureInPicture {
  PictureInPicture._();
  static final PictureInPicture instance = PictureInPicture._();

  static const MethodChannel _channel = MethodChannel('blackpearl/pip');

  /// Only Android 8 and later have it, and only where the device allows it.
  bool supported = false;

  /// Whether the app is showing as the small window now.
  final ValueNotifier<bool> active = ValueNotifier(false);

  /// The window's Play/Pause button.
  VoidCallback? onToggle;

  bool _started = false;

  Future<void> start() async {
    if (_started || kIsWeb || !Platform.isAndroid) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'changed':
          active.value = call.arguments == true;
        case 'toggle':
          onToggle?.call();
      }
      return null;
    });
    try {
      supported = await _channel.invokeMethod<bool>('supported') ?? false;
    } on PlatformException {
      supported = false;
    } on MissingPluginException {
      supported = false;
    }
  }

  /// Says whether leaving the app should move the video to the small window, the video's shape, and whether it plays
  /// (for the window's button).
  Future<void> update({required bool wanted, int width = 16, int height = 9, bool playing = false}) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('update', {'wanted': wanted, 'width': width, 'height': height, 'playing': playing});
    } on PlatformException {
      // The activity is gone; the next update sets it again.
    }
  }

  Future<void> enter() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('enter');
    } on PlatformException {
      // Refused, as while the app isn't showing.
    }
  }
}
