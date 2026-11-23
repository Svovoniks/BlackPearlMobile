import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android's picture in picture for the phone's player: the video keeps playing in a small window over other apps.
/// While the player screen wants it, leaving the app (Home, or switching apps) moves the video there by itself; the
/// player's button does it at once. The window has a Play/Pause button.
///
/// The Android side lives with the activity, which can come and go while the app runs (the background service keeps
/// the app alive without one). Each new activity says so (`ready`), and gets the player's last wishes again.
class PictureInPicture {
  PictureInPicture._();
  static final PictureInPicture instance = PictureInPicture._();

  static const MethodChannel _channel = MethodChannel('blackpearl/pip');

  /// Only Android 8 and later have it, and only where the device allows it. Known once an activity has said so.
  bool supported = false;

  /// Whether the app is showing as the small window now.
  final ValueNotifier<bool> active = ValueNotifier(false);

  /// The window's Play/Pause button.
  VoidCallback? onToggle;

  /// The user closed the small window: the video stops there.
  VoidCallback? onDismissed;

  /// The window shows again after the screen was off; the app isn't in the background any more.
  VoidCallback? onShown;

  /// The same, for the app as a whole: its link to the PC comes back, as on any return to the app.
  VoidCallback? onAppShown;

  /// An activity attached and learned nothing yet: whoever uses picture in picture says what it wants again.
  VoidCallback? onReady;

  bool _started = false;
  Map<String, Object?>? _last;

  void start() {
    if (_started || kIsWeb || !Platform.isAndroid) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'ready':
          supported = call.arguments == true;
          final last = _last;
          if (last != null) unawaited(_invoke('update', last));
          onReady?.call();
        case 'changed':
          active.value = call.arguments == true;
        case 'dismissed':
          active.value = false;
          onDismissed?.call();
        case 'shown':
          onShown?.call();
          onAppShown?.call();
        case 'toggle':
          onToggle?.call();
      }
      return null;
    });
    unawaited(refresh());
  }

  /// Asks again whether picture in picture is there, as when the player opens: the app may have started without a
  /// window to ask.
  Future<void> refresh() async {
    if (!_started) return;
    supported = await _invoke<bool>('supported', null) ?? supported;
  }

  /// Says whether leaving the app should move the video to the small window, the video's shape, and whether it plays
  /// (for the window's button).
  Future<void> update({required bool wanted, int width = 16, int height = 9, bool playing = false}) async {
    final arguments = {'wanted': wanted, 'width': width, 'height': height, 'playing': playing};
    _last = arguments;
    if (!supported) return;
    await _invoke<void>('update', arguments);
  }

  Future<void> enter() async {
    if (!supported) return;
    await _invoke<void>('enter', null);
  }

  /// The player closed, or asks for a shape of its own. Back from the small window, a player that turns with the phone
  /// keeps the shape it had before (portrait or landscape) until the phone is turned to match; this ends that at once.
  Future<void> release() async {
    if (!supported) return;
    await _invoke<void>('release', null);
  }

  // No activity attached (or one going away) answers nothing; the next one asks again.
  static Future<T?> _invoke<T>(String method, Object? arguments) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
