import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
// The libmpv media_kit loaded, so reads go to the same library and player.
// ignore: implementation_imports
import 'package:media_kit/src/player/native/core/native_library.dart';

/// Reads libmpv properties away from the app's main thread.
///
/// A libmpv read waits for mpv's core, which can be busy for seconds: opening a stream that has stalled, or starting
/// the phone's audio output. media_kit's `getProperty` reads on the thread that calls it, so a read made from the
/// screen froze it, and Android closed the app as not responding. Each read here runs on a short-lived isolate. A read
/// that takes too long gives null, and the caller falls back on media_kit's state.
class MpvReads {
  MpvReads._() : _reader = _readOnIsolate;

  /// Reads with [reader] in place of libmpv; players are any object.
  @visibleForTesting
  MpvReads.withReader(Future<String?> Function(Object player, String property) reader) : _reader = reader;

  static final MpvReads instance = MpvReads._();

  final Future<String?> Function(Object player, String property) _reader;

  // Reads still running, by player and property. A property is read once at a time, so a core that stays busy holds
  // one isolate per property rather than one per tick.
  final Map<Object, Map<String, Future<String?>>> _running = {};
  final Expando<bool> _released = Expando();

  /// [property] of [player] as text, or null when [player] isn't libmpv's, is being released, or the read doesn't
  /// finish [within] this long.
  Future<String?> read(Player player, String property, {required Duration within}) async {
    final native = player.platform;
    return native is NativePlayer ? readFrom(native, property, within: within) : null;
  }

  /// [read] for the player [key] stands for.
  @visibleForTesting
  Future<String?> readFrom(Object key, String property, {required Duration within}) {
    if (_released[key] == true) return Future.value();
    final reads = _running.putIfAbsent(key, () => {});
    var running = reads[property];
    if (running == null) {
      final started = _start(key, property);
      reads[property] = started;
      unawaited(
        started.whenComplete(() {
          if (identical(reads[property], started)) reads.remove(property);
          if (reads.isEmpty && identical(_running[key], reads)) _running.remove(key);
        }),
      );
      running = started;
    }
    return running.timeout(within, onTimeout: () => null);
  }

  /// Call before disposing [player]: no new reads start, and reads still running get up to [within] to finish.
  /// media_kit frees libmpv a few seconds after `dispose`, and a read still running then would use a freed player.
  Future<void> release(Player player, {Duration within = const Duration(seconds: 4)}) async {
    final native = player.platform;
    if (native is NativePlayer) await releaseFrom(native, within: within);
  }

  /// [release] for the player [key] stands for.
  @visibleForTesting
  Future<void> releaseFrom(Object key, {Duration within = const Duration(seconds: 4)}) async {
    _released[key] = true;
    final reads = _running[key];
    if (reads == null || reads.isEmpty) return;
    await Future.wait(reads.values.toList()).timeout(within, onTimeout: () => const []);
  }

  Future<String?> _start(Object key, String property) async {
    try {
      return await _reader(key, property);
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _readOnIsolate(Object player, String property) async {
    final handle = await (player as NativePlayer).handle;
    return _readOnIsolateAt(NativeLibrary.path, handle, property);
  }

  // Static and apart from the player, so the closure sent to the isolate carries only the library, handle and name.
  static Future<String?> _readOnIsolateAt(String library, int handle, String property) =>
      Isolate.run(() => _readNow(library, handle, property));

  static String? _readNow(String library, int handle, String property) {
    final mpv = DynamicLibrary.open(library);
    final get = mpv
        .lookupFunction<Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)>(
          'mpv_get_property_string',
        );
    final free = mpv.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('mpv_free');
    final name = property.toNativeUtf8();
    try {
      final value = get(Pointer<Void>.fromAddress(handle), name);
      if (value == nullptr) return null;
      try {
        return value.toDartString();
      } finally {
        free(value.cast());
      }
    } finally {
      malloc.free(name);
    }
  }
}
