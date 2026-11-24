import 'package:flutter/services.dart';

import 'transport.dart';

/// [LocalNetworkAccess] on Android (android/.../LocalNetwork.kt): asks whether the phone is on Wi-Fi or Ethernet, and
/// makes that network the app's while it opens sockets to the PC's home address. Without it, a home network whose
/// internet is down (Android then makes mobile data the default) would be tried over mobile data.
class AndroidLocalNetwork implements LocalNetworkAccess {
  AndroidLocalNetwork({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('blackpearl/network');

  final MethodChannel _channel;

  /// How long one platform call may take before it counts as unanswered.
  static const callTimeout = Duration(seconds: 2);

  // Tries under way. Tries that overlap (the PC in use and one kept during a pairing attempt) share one binding, undone
  // once the last has finished. The platform calls go one after another, each deciding from the tries under way when
  // it runs, so an unbind can't overtake a newer try's bind.
  int _runs = 0;
  Future<void> _calls = Future.value();
  // Null: nothing asked of the platform. True: the process is bound. False: no binding was needed or possible.
  bool? _bound;

  @override
  Future<bool> available() async {
    final answer = await _call('available');
    // No answer, or none in time: can't tell, so try, as without this check.
    return answer is bool ? answer : true;
  }

  @override
  Future<T> run<T>(Future<T> Function() attempt) async {
    try {
      _runs++;
      await _settle();
      return await attempt();
    } finally {
      _runs--;
      await _settle();
    }
  }

  // Never fails: a failed call leaves the queue working for the next one.
  Future<void> _settle() => _calls = _calls.then((_) async {
    if (_runs > 0 && _bound == null) {
      final answer = await _call('bind');
      // A bind that didn't answer in time may still have happened: it is undone like one that did.
      _bound = answer == true || identical(answer, _noAnswer);
    } else if (_runs == 0 && _bound != null) {
      if (_bound!) await _call('unbind');
      _bound = null;
    }
  }).catchError((Object _) {});

  // What [_call] returns for a call that didn't answer within [callTimeout].
  static const _noAnswer = Object();

  /// The platform's answer, [_noAnswer] for one that took too long, or null for any failure: the binding only helps, and
  /// a try must go on without it.
  Future<Object?> _call(String method) async {
    try {
      // A platform side that doesn't answer mustn't hold the try, or the calls queued behind it.
      return await _channel.invokeMethod<Object?>(method).timeout(callTimeout, onTimeout: () => _noAnswer);
    } catch (_) {
      // Android drops a binding when the process ends; nothing else to do.
      return null;
    }
  }
}
