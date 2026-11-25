/// WebRTC peer connections with data channels only, over libdatachannel (src/).
///
/// libdatachannel works on its own threads and reports back through callbacks, which arrive here as events on the
/// isolate that made the first peer connection. Calls that can wait on those threads (making a description, which opens
/// the ICE sockets; adding a candidate; closing) run on a short-lived isolate, so they never hold up the screen.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// A peer connection's state, as libdatachannel numbers it.
enum RtcState { created, connecting, connected, disconnected, failed, closed }

/// How far gathering local candidates has got.
enum RtcGathering { idle, inProgress, complete }

/// A libdatachannel call that failed, with its negative error code.
class RtcException implements Exception {
  const RtcException(this.operation, this.code);
  final String operation;
  final int code;

  @override
  String toString() => 'RtcException: $operation failed ($code)';
}

/// One peer connection. Its local description is made only when asked for ([setLocalDescription]), never by itself.
class RtcPeer {
  RtcPeer._(this.id);

  /// A new peer connection with [iceServers] as libdatachannel takes them (`stun:host:port`,
  /// `turn:user:pass@host:port?transport=udp`, with user and password percent-encoded), going only through a relay when
  /// [relayOnly]. Throws [RtcException] when libdatachannel refuses the configuration.
  factory RtcPeer.create({List<String> iceServers = const [], bool relayOnly = false}) {
    _Events.start();
    final id = _withStrings(iceServers, (servers) => _bindings.peerCreate(servers, iceServers.length, relayOnly ? 1 : 0));
    if (id < 0) throw RtcException('create a peer connection', id);
    final peer = RtcPeer._(id);
    _Events.peers[id] = peer;
    return peer;
  }

  final int id;

  /// The local description libdatachannel made: its SDP and type (`offer` or `answer`).
  void Function(String sdp, String type)? onDescription;

  /// A local candidate line (`candidate:…`) and its media id.
  void Function(String candidate, String mid)? onCandidate;
  void Function(RtcState state)? onState;
  void Function(RtcGathering state)? onGathering;

  /// A channel the other side opened.
  void Function(RtcChannel channel)? onChannel;

  RtcState _state = RtcState.created;
  RtcState get state => _state;
  bool _closed = false;
  bool get closed => _closed;

  // Calls that wait on libdatachannel, one after another, in the order they were made.
  Future<void> _queue = Future.value();

  Future<T> _enqueue<T>(Future<T> Function() call) {
    final result = _queue.then((_) => call());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// A reliable, ordered channel labelled [label]. Create channels before the offer, so it carries them.
  RtcChannel createChannel(String label) {
    if (_closed) throw const RtcException('create a data channel on a closed peer connection', -2);
    final dc = _withString(label, (text) => _bindings.channelCreate(id, text));
    if (dc < 0) throw RtcException('create a data channel', dc);
    return _Events.adopt(dc, label, this);
  }

  /// Makes the local description of [type] (`offer`, `answer`, or null to let libdatachannel pick); it arrives through
  /// [onDescription]. Gathering starts with it, and the ICE sockets are open once this completes.
  Future<void> setLocalDescription([String? type]) => _enqueue(() async {
    if (_closed) return;
    final result = await _off1(_setLocalDescriptionNow, id, type);
    if (result < 0) throw RtcException('make the local description', result);
  });

  Future<void> setRemoteDescription(String sdp, String type) => _enqueue(() async {
    if (_closed) return;
    final result = await _off2(_setRemoteDescriptionNow, id, sdp, type);
    if (result < 0) throw RtcException('set the remote description', result);
  });

  /// Adds the other side's candidate line (with or without `a=`) for media id [mid], or the first media when null.
  Future<void> addRemoteCandidate(String candidate, String? mid) => _enqueue(() async {
    if (_closed) return;
    final result = await _off2(_addRemoteCandidateNow, id, candidate, mid);
    if (result < 0) throw RtcException('add a remote candidate', result);
  });

  /// The candidate lines of the pair ICE chose, or null while there is none.
  Future<({String local, String remote})?> selectedPair() async {
    if (_closed) return null;
    return _offPair(id);
  }

  /// Closes the connection and its channels, and frees them. Nothing is reported after this is called.
  Future<void> close() {
    if (_closed) return _queue;
    _closed = true;
    onDescription = null;
    onCandidate = null;
    onState = null;
    onGathering = null;
    onChannel = null;
    final channels = _Events.channels.values.where((c) => identical(c.peer, this)).toList();
    for (final channel in channels) {
      channel._detach();
    }
    return _enqueue(() async {
      await _offDelete(id);
      _Events.peers.remove(id);
      for (final channel in channels) {
        _Events.channels.remove(channel.id);
      }
    });
  }
}

/// A data channel of an [RtcPeer].
class RtcChannel {
  RtcChannel._(this.id, this.label, this.peer);

  final int id;
  final String label;
  final RtcPeer peer;

  void Function()? onOpen;
  void Function()? onClosed;
  void Function(String message)? onError;
  void Function(String text)? onText;
  void Function(Uint8List data)? onBinary;

  bool _open = false;
  bool _detached = false;

  /// Whether the channel is open: it has opened and not closed since.
  bool get isOpen => _open && !_detached;

  /// Sends [text] as a text message. False when the channel isn't open or libdatachannel refused it.
  bool sendText(String text) {
    if (!isOpen) return false;
    return _withString(text, (native) => _bindings.sendText(id, native)) >= 0;
  }

  /// Sends [data] as a binary message. False when the channel isn't open or libdatachannel refused it.
  bool sendBinary(Uint8List data) {
    if (!isOpen) return false;
    final native = malloc<Uint8>(data.isEmpty ? 1 : data.length);
    try {
      native.asTypedList(data.length).setAll(0, data);
      return _bindings.sendBinary(id, native, data.length) >= 0;
    } finally {
      malloc.free(native);
    }
  }

  /// Closes the channel. [onClosed] follows, unless the peer connection is closed first.
  void close() {
    if (_detached) return;
    _bindings.channelClose(id);
  }

  void _detach() {
    _detached = true;
    _open = false;
    onOpen = null;
    onClosed = null;
    onError = null;
    onText = null;
    onBinary = null;
  }
}

/// Sends libdatachannel's log at [level] and above to logcat on Android, and to [onLog] when given (one listener at a
/// time). Levels follow libdatachannel's: 1 fatal, 2 error, 3 warning, 4 info, 5 debug, 6 verbose; 0 is none.
void rtcLog(int level, {void Function(int level, String message)? onLog}) {
  _Events.start();
  _Events.onLog = onLog;
  _bindings.log(level, onLog != null ? 1 : 0);
}

// What happened, as the shim numbers it (src/blackpearl_datachannel.cpp).
abstract final class _Event {
  static const description = 1;
  static const candidate = 2;
  static const state = 3;
  static const gathering = 4;
  static const channel = 5;
  static const open = 6;
  static const closed = 7;
  static const error = 8;
  static const text = 9;
  static const binary = 10;
  static const log = 11;
}

typedef _ListenerNative = Void Function(Int32, Int32, Int32, Pointer<Uint8>, Int32, Pointer<Uint8>, Int32);

abstract final class _Events {
  static NativeCallable<_ListenerNative>? _listener;
  static final Map<int, RtcPeer> peers = {};
  static final Map<int, RtcChannel> channels = {};
  static void Function(int level, String message)? onLog;

  // Events for a channel the other side opened that came before the event announcing it. Events from different
  // libdatachannel threads can arrive in either order.
  static final Map<int, List<void Function(RtcChannel)>> _early = {};

  static void start() {
    if (_listener != null) return;
    final listener = NativeCallable<_ListenerNative>.listener(_on);
    // The isolate stays alive for other reasons; this alone shouldn't keep it.
    listener.keepIsolateAlive = false;
    _listener = listener;
    _bindings.setListener(listener.nativeFunction);
  }

  static RtcChannel adopt(int id, String label, RtcPeer peer) {
    final channel = RtcChannel._(id, label, peer);
    channels[id] = channel;
    final early = _early.remove(id);
    if (early != null) {
      // After whoever made it has set its callbacks.
      scheduleMicrotask(() {
        for (final apply in early) {
          apply(channel);
        }
      });
    }
    return channel;
  }

  static void _on(int event, int id, int value, Pointer<Uint8> data, int size, Pointer<Uint8> extra, int extraSize) {
    try {
      String text(Pointer<Uint8> pointer, int length) =>
          pointer == nullptr ? '' : utf8.decode(pointer.asTypedList(length), allowMalformed: true);
      switch (event) {
        case _Event.log:
          onLog?.call(value, text(data, size));
        case _Event.description:
          peers[id]?.onDescription?.call(text(data, size), text(extra, extraSize));
        case _Event.candidate:
          peers[id]?.onCandidate?.call(text(data, size), text(extra, extraSize));
        case _Event.state:
          final peer = peers[id];
          if (peer == null || value < 0 || value >= RtcState.values.length) break;
          peer._state = RtcState.values[value];
          peer.onState?.call(peer._state);
        case _Event.gathering:
          if (value < 0 || value >= RtcGathering.values.length) break;
          peers[id]?.onGathering?.call(RtcGathering.values[value]);
        case _Event.channel:
          final peer = peers[id];
          if (peer == null || peer._closed) break;
          final opened = adopt(value, text(data, size), peer);
          peer.onChannel?.call(opened);
        case _Event.open || _Event.closed || _Event.error || _Event.text || _Event.binary:
          final apply = _channelEvent(event, text(data, size), data == nullptr ? Uint8List(0) : Uint8List.fromList(data.asTypedList(size)));
          final channel = channels[id];
          if (channel != null) {
            apply(channel);
          } else {
            final early = _early.putIfAbsent(id, () => []);
            // A channel nobody ever takes (its peer connection closed first) shouldn't grow without end.
            if (early.length < 64) early.add(apply);
          }
      }
    } finally {
      if (data != nullptr) _bindings.free(data.cast());
      if (extra != nullptr) _bindings.free(extra.cast());
    }
  }

  static void Function(RtcChannel) _channelEvent(int event, String text, Uint8List bytes) => switch (event) {
    _Event.open => (channel) {
      if (channel._detached) return;
      channel._open = true;
      channel.onOpen?.call();
    },
    _Event.closed => (channel) {
      if (channel._detached) return;
      channel._open = false;
      channel.onClosed?.call();
    },
    _Event.error => (channel) => channel.onError?.call(text),
    _Event.text => (channel) => channel.onText?.call(text),
    _ => (channel) => channel.onBinary?.call(bytes),
  };
}

// The calls made on a short-lived isolate. The closures are made here, at the top level, so what is sent there carries
// only the function and its numbers and text, never the peer connection and whatever its callbacks hold.

Future<int> _off1(int Function(int, String?) call, int pc, String? a) => Isolate.run(() => call(pc, a));

Future<int> _off2<A, B>(int Function(int, A, B) call, int pc, A a, B b) => Isolate.run(() => call(pc, a, b));

Future<({String local, String remote})?> _offPair(int pc) => Isolate.run(() => _selectedPairNow(pc));

Future<int> _offDelete(int pc) => Isolate.run(() => _deleteNow(pc));

int _setLocalDescriptionNow(int pc, String? type) =>
    type == null ? _bindings.setLocalDescription(pc, nullptr) : _withString(type, (t) => _bindings.setLocalDescription(pc, t));

int _setRemoteDescriptionNow(int pc, String sdp, String type) =>
    _withString(sdp, (s) => _withString(type, (t) => _bindings.setRemoteDescription(pc, s, t)));

int _addRemoteCandidateNow(int pc, String candidate, String? mid) => _withString(
  candidate,
  (c) => mid == null ? _bindings.addRemoteCandidate(pc, c, nullptr) : _withString(mid, (m) => _bindings.addRemoteCandidate(pc, c, m)),
);

({String local, String remote})? _selectedPairNow(int pc) {
  const size = 512;
  final local = malloc<Uint8>(size), remote = malloc<Uint8>(size);
  try {
    if (_bindings.selectedPair(pc, local.cast(), size, remote.cast(), size) < 0) return null;
    return (local: local.cast<Utf8>().toDartString(), remote: remote.cast<Utf8>().toDartString());
  } finally {
    malloc.free(local);
    malloc.free(remote);
  }
}

int _deleteNow(int pc) => _bindings.peerDelete(pc);

T _withString<T>(String text, T Function(Pointer<Utf8> native) use) {
  final native = text.toNativeUtf8();
  try {
    return use(native);
  } finally {
    malloc.free(native);
  }
}

T _withStrings<T>(List<String> texts, T Function(Pointer<Pointer<Utf8>> native) use) {
  final array = malloc<Pointer<Utf8>>(texts.isEmpty ? 1 : texts.length);
  for (var i = 0; i < texts.length; i++) {
    array[i] = texts[i].toNativeUtf8();
  }
  try {
    return use(array);
  } finally {
    for (var i = 0; i < texts.length; i++) {
      malloc.free(array[i]);
    }
    malloc.free(array);
  }
}

// Opened in each isolate that uses it: the library loads once per process.
final _Bindings _bindings = _Bindings(
  DynamicLibrary.open(Platform.isWindows ? 'blackpearl_datachannel.dll' : 'libblackpearl_datachannel.so'),
);

class _Bindings {
  _Bindings(DynamicLibrary library)
    : setListener = library.lookupFunction<
        Void Function(Pointer<NativeFunction<_ListenerNative>>),
        void Function(Pointer<NativeFunction<_ListenerNative>>)
      >('bp_dc_set_listener'),
      free = library.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('bp_dc_free'),
      log = library.lookupFunction<Void Function(Int32, Int32), void Function(int, int)>('bp_dc_log'),
      peerCreate = library.lookupFunction<
        Int32 Function(Pointer<Pointer<Utf8>>, Int32, Int32),
        int Function(Pointer<Pointer<Utf8>>, int, int)
      >('bp_dc_peer_create'),
      setLocalDescription = library.lookupFunction<Int32 Function(Int32, Pointer<Utf8>), int Function(int, Pointer<Utf8>)>(
        'bp_dc_set_local_description',
      ),
      setRemoteDescription = library.lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Pointer<Utf8>),
        int Function(int, Pointer<Utf8>, Pointer<Utf8>)
      >('bp_dc_set_remote_description'),
      addRemoteCandidate = library.lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Pointer<Utf8>),
        int Function(int, Pointer<Utf8>, Pointer<Utf8>)
      >('bp_dc_add_remote_candidate'),
      selectedPair = library.lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Int32, Pointer<Utf8>, Int32),
        int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int)
      >('bp_dc_selected_pair'),
      peerDelete = library.lookupFunction<Int32 Function(Int32), int Function(int)>('bp_dc_peer_delete'),
      channelCreate = library.lookupFunction<Int32 Function(Int32, Pointer<Utf8>), int Function(int, Pointer<Utf8>)>(
        'bp_dc_channel_create',
      ),
      sendText = library.lookupFunction<Int32 Function(Int32, Pointer<Utf8>), int Function(int, Pointer<Utf8>)>(
        'bp_dc_send_text',
      ),
      sendBinary = library.lookupFunction<Int32 Function(Int32, Pointer<Uint8>, Int32), int Function(int, Pointer<Uint8>, int)>(
        'bp_dc_send_binary',
      ),
      channelClose = library.lookupFunction<Int32 Function(Int32), int Function(int)>('bp_dc_channel_close');

  final void Function(Pointer<NativeFunction<_ListenerNative>>) setListener;
  final void Function(Pointer<Void>) free;
  final void Function(int, int) log;
  final int Function(Pointer<Pointer<Utf8>>, int, int) peerCreate;
  final int Function(int, Pointer<Utf8>) setLocalDescription;
  final int Function(int, Pointer<Utf8>, Pointer<Utf8>) setRemoteDescription;
  final int Function(int, Pointer<Utf8>, Pointer<Utf8>) addRemoteCandidate;
  final int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int) selectedPair;
  final int Function(int) peerDelete;
  final int Function(int, Pointer<Utf8>) channelCreate;
  final int Function(int, Pointer<Utf8>) sendText;
  final int Function(int, Pointer<Uint8>, int) sendBinary;
  final int Function(int) channelClose;
}
