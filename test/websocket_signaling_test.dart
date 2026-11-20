import 'dart:async';

import 'package:blackpearl_mobile/connection/webrtc_peer.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A WebSocket that connects when the test says so.
class SlowChannel implements WebSocketChannel {
  final Completer<void> connected = Completer<void>();
  final ClosingSink closingSink = ClosingSink();

  @override
  Future<void> get ready => connected.future;
  @override
  WebSocketSink get sink => closingSink;
  @override
  Stream get stream => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ClosingSink implements WebSocketSink {
  int closes = 0;
  @override
  Future close([int? closeCode, String? closeReason]) async => closes++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('a socket that connects in time is handed over, not closed', () {
    fakeAsync((async) {
      final channel = SlowChannel();
      Object? result;
      WebSocketSignaling.open(channel).then((s) => result = s);
      async.elapse(const Duration(seconds: 3));
      channel.connected.complete();
      async.flushMicrotasks();
      expect(result, isNotNull);
      expect(channel.closingSink.closes, 0);
    });
  });

  test('the connect timeout closes the socket, and closes it again if it connects late', () {
    fakeAsync((async) {
      final channel = SlowChannel();
      Object? error;
      WebSocketSignaling.open(channel).catchError((Object e) {
        error = e;
        return Future<Never>.error(e);
      }).ignore();
      async.elapse(const Duration(seconds: 15, milliseconds: 1));
      expect(error, isA<TimeoutException>());
      expect(channel.closingSink.closes, greaterThanOrEqualTo(1), reason: 'closed when the wait ends');
      final before = channel.closingSink.closes;
      channel.connected.complete();
      async.flushMicrotasks();
      expect(channel.closingSink.closes, before + 1, reason: 'a connection that completes late is closed too');
    });
  });

  test('a socket that fails to connect is closed', () {
    fakeAsync((async) {
      final channel = SlowChannel();
      Object? error;
      WebSocketSignaling.open(channel).then<void>((_) {}, onError: (Object e) => error = e);
      channel.connected.completeError(WebSocketChannelException('refused'));
      async.flushMicrotasks();
      expect(error, isA<WebSocketChannelException>());
      expect(channel.closingSink.closes, greaterThanOrEqualTo(1));
    });
  });
}
