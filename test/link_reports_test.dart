import 'dart:convert';
import 'dart:typed_data';

import 'package:blackpearl_mobile/connection/media_channel.dart';
import 'package:blackpearl_mobile/connection/remote_link.dart';
import 'package:blackpearl_mobile/diagnostics/crash_reports.dart';
import 'package:blackpearl_mobile/diagnostics/link_reports.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'connection_test.dart' show Harness, pairedTarget, phoneId, secret;

// Timing the link to the PC (PHONE-REMOTE.md, "Measuring the link"): what the phone reports about it, and that it answers
// the PC's own pings.
void main() {
  setUp(() => LinkReports.recorded = []);
  tearDown(LinkReports.reset);

  List<LinkReport> reports(String name) => LinkReports.recorded!.where((r) => r.name == name).toList();

  // Links up with a PC whose welcome lists [features].
  void link(FakeAsync async, Harness h, List<String> features) {
    h.socket.receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
    h.socket.receive({'type': 'remote-online'});
    async.flushMicrotasks();
    h.pcSignal(secret, phoneId, h.socket.signals().first.session, 'sdp', jsonEncode({'type': 'answer', 'sdp': 'v=0'}));
    async.flushMicrotasks();
    h.peer.open();
    h.peer.receive({'type': 'welcome', 'protocol': 1, 'app': '0.3.166', 'pc': 'Living room', 'features': features});
    async.flushMicrotasks();
  }

  // A frame as PHONE-REMOTE.md lays it out, with [length] bytes of data.
  Uint8List frame(int id, int offset, int total, int resourceLength, int length) {
    final bytes = Uint8List(24 + length);
    ByteData.sublistView(bytes)
      ..setUint32(0, id, Endian.little)
      ..setInt32(4, offset, Endian.little)
      ..setInt32(8, total, Endian.little)
      ..setInt64(16, resourceLength, Endian.little);
    return bytes;
  }

  test("reports how the link was set up: each stage in order, how it was introduced, and the PC app's version", () {
    fakeAsync((async) {
      final h = Harness(pairedTarget);
      h.connection.start();
      async.flushMicrotasks();
      h.socket.receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
      h.socket.receive({'type': 'remote-online'});
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 200));
      h.pcSignal(secret, phoneId, h.socket.signals().first.session, 'sdp', jsonEncode({'type': 'answer', 'sdp': 'v=0'}));
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 300));
      h.peer.open();
      async.elapse(const Duration(milliseconds: 100));
      h.peer.receive({'type': 'welcome', 'protocol': 1, 'app': '0.3.166', 'pc': 'Living room', 'features': ['ping']});
      async.flushMicrotasks();

      final report = reports(LinkReports.connectName).single;
      expect(report.status, 'ok');
      expect(report.tags, {'link.outcome': 'connected', 'link.network': 'server', 'link.pairing': 'no', 'pc.app': '0.3.166'});
      expect(report.stages.map((s) => s.$1), ['offer', 'answer', 'link', 'welcome']);
      expect([for (final (_, start, end) in report.stages) end.difference(start).inMilliseconds], [0, 200, 300, 100]);
      expect(report.end.difference(report.start), const Duration(milliseconds: 600));
      h.connection.dispose();
    });
  });

  test("answers the PC's pings, and reports round trips and reads in stretches and when the link goes", () {
    fakeAsync((async) {
      final h = Harness(pairedTarget);
      h.connection.start();
      async.flushMicrotasks();
      link(async, h, ['ping']);
      h.peer.sent.clear();
      h.peer.receive({'type': 'ping', 'number': 7});
      expect(h.peer.sent.single, {'type': 'pong', 'number': 7}, reason: 'the PC times the link with its own pings');

      // A read of 200,000 bytes whose first frame takes 30 ms and whose last arrives half a second after it was asked for.
      h.peer.onMediaOpen!();
      final read = h.connection.media!.read('file/a', 0, 200000);
      async.elapse(const Duration(milliseconds: 30));
      h.peer.onMediaBinary!(frame(read.id, 0, 200000, 1000000, 100000));
      async.elapse(const Duration(milliseconds: 470));
      h.peer.onMediaBinary!(frame(read.id, 100000, 200000, 1000000, 100000));
      async.flushMicrotasks();

      // Ten minutes of pings, every 10 seconds from the link coming up, each answered after 40 ms.
      async.elapse(const Duration(milliseconds: 9500));
      for (var i = 0; i < 60; i++) {
        expect(h.peer.sent.where((m) => m['type'] == 'ping'), hasLength(1));
        async.elapse(const Duration(milliseconds: 40));
        for (final ping in h.peer.sent.where((m) => m['type'] == 'ping').toList()) {
          h.peer.receive({'type': 'pong', 'number': ping['number']});
        }
        h.peer.sent.removeWhere((m) => m['type'] == 'ping');
        async.elapse(const Duration(milliseconds: 9960));
      }
      final stretch = reports(LinkReports.linkName).single;
      expect(stretch.tags, {'link.path': 'home', 'link.network': 'server', 'link.end': 'open', 'pc.app': '0.3.166'});
      expect(stretch.end.difference(stretch.start), LinkReports.window);
      final m = stretch.measurements;
      expect(m['rtt'], (40.0, 'ms'));
      expect(m['rtt_max'], (40.0, 'ms'));
      expect(m['pings_unanswered'], (0, ''));
      expect(m['pings']!.$1, greaterThanOrEqualTo(59));
      expect(m['media_bytes'], (200000, 'byte'));
      expect(m['media_reads'], (1, ''));
      expect(m['first_byte'], (30.0, 'ms'));
      expect(m['media_kbps'], (3200.0, ''), reason: '200,000 bytes in half a second');
      expect(m.length, lessThanOrEqualTo(LinkReports.measurementLimit));

      h.peer.lose();
      async.flushMicrotasks();
      final both = reports(LinkReports.linkName);
      expect(both, hasLength(2));
      expect(both.last.tags['link.end'], 'link-closed');
      expect(both.last.measurements['media_reads'], (0, ''), reason: 'the read counted in the stretch before');
      h.connection.dispose();
    });
  });

  test("a link with nothing measured, as with a PC from before pings and no video, isn't reported", () {
    fakeAsync((async) {
      final h = Harness(pairedTarget);
      h.connection.start();
      async.flushMicrotasks();
      link(async, h, ['library']);
      async.elapse(const Duration(minutes: 25));
      h.connection.dispose();
      async.flushMicrotasks();
      expect(reports(LinkReports.linkName), isEmpty);
      expect(reports(LinkReports.connectName), hasLength(1));
    });
  });

  test('a setup that fails is reported by its code, once a half hour', () {
    fakeAsync((async) {
      final h = Harness(pairedTarget);
      h.connection.start();
      async.flushMicrotasks();
      for (var i = 0; i < 3; i++) {
        h.socket.receive({'type': 'remote-welcome', 'data': '{"iceServers":[]}'});
        h.socket.receive({'type': 'remote-online'});
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 20500));
        expect(h.connection.status.phase, LinkPhase.failed);
        async.elapse(const Duration(seconds: 10));
      }
      final failed = reports(LinkReports.connectName).single;
      expect(failed.status, 'deadline_exceeded');
      expect(failed.tags['link.outcome'], 'no-answer');
      expect(failed.stages.map((s) => s.$1), ['offer', 'answer'], reason: 'it waited for the answer when it failed');
      expect(failed.measurements['failures_before'], (0, ''));
      h.connection.dispose();
    });
  });

  group('LinkStats', () {
    test('a pong times the ping it answers, once; a late one or one for no ping counts for nothing', () {
      final start = DateTime(2026, 11, 27, 20);
      final stats = LinkStats(start);
      stats.pingSent(1, start);
      stats.pingSent(2, start.add(const Duration(seconds: 1)));
      stats.pingSent(3, start.add(const Duration(seconds: 2)));
      expect(stats.pong(1, start.add(const Duration(milliseconds: 40))), isTrue);
      expect(stats.pong(2, start.add(const Duration(milliseconds: 1020))), isTrue);
      expect(stats.pong(2, start.add(const Duration(milliseconds: 1500))), isFalse);
      expect(stats.pong(99, start.add(const Duration(seconds: 2))), isFalse);
      expect(stats.pong(3, start.add(const Duration(seconds: 13))), isFalse);
      final window = stats.take(start.add(const Duration(seconds: 14)), MediaUse.none);
      expect((window.pings, window.pongs, window.unanswered, window.rttMedian, window.rttP90, window.rttMax), (3, 2, 1, 20.0, 40.0, 40.0));
      expect(window.measured, isTrue);
      final next = stats.take(start.add(const Duration(seconds: 20)), MediaUse.none);
      expect((next.pings, next.rttMedian, next.measured), (0, null, false));
      expect(next.measurements.keys, isNot(contains('rtt')));
    });

    test("pings a sleeping phone's PC leaves unanswered don't make a stretch worth sending", () {
      final start = DateTime(2026, 11, 27, 20);
      final stats = LinkStats(start)..pingSent(1, start);
      final window = stats.take(start.add(const Duration(minutes: 10)), MediaUse.none);
      expect(window.unanswered, 1);
      expect(window.measured, isFalse);
    });

    test('percentiles take the nearest rank', () {
      expect(LinkStats.percentile([1, 2, 3, 4], 0.5), 2);
      expect(LinkStats.percentile([for (var i = 1; i <= 10; i++) i.toDouble()], 0.9), 9);
      expect(LinkStats.percentile([], 0.5), isNull);
    });

    test('speed is only given once there is enough to tell', () {
      expect(const MediaUse(bytes: 1000000, reads: 4, busy: Duration(seconds: 2)).kbps, 4000);
      expect(const MediaUse(bytes: 1000000, reads: 4, busy: Duration(milliseconds: 400)).kbps, isNull);
      expect(const MediaUse(bytes: 1000, reads: 1, busy: Duration(seconds: 2)).kbps, isNull);
    });

    test("an app's version is kept, and anything that isn't one is not", () {
      expect(LinkReports.version('0.3.166'), '0.3.166');
      expect(LinkReports.version('Living room'), 'other');
      expect(LinkReports.version(null), isNull);
    });
  });

  test('the media channel counts how long reads were in flight, not the time between them', () {
    fakeAsync((async) {
      final sent = <Map<String, dynamic>>[];
      final reader = MediaReader(send: (text) => sent.add(jsonDecode(text) as Map<String, dynamic>));
      final first = reader.read('file/a', 0, 100000);
      async.elapse(const Duration(milliseconds: 250));
      reader.onBinary(frame(first.id, 0, 100000, 1000000, 100000));
      async.elapse(const Duration(seconds: 5));
      final second = reader.read('file/a', 100000, 100000);
      async.elapse(const Duration(milliseconds: 250));
      reader.onBinary(frame(second.id, 0, 100000, 1000000, 100000));
      final use = reader.takeUse();
      expect((use.bytes, use.reads, use.busy), (200000, 2, const Duration(milliseconds: 500)));
      expect(use.firstBytes, [250.0, 250.0]);
      expect(use.kbps, 3200);
      expect(reader.takeUse().bytes, 0, reason: 'each stretch starts empty');
    });
  });

  test('every report on the link is sent; other timings at the usual rate', () {
    final options = SentryFlutterOptions();
    CrashReports.configure(options, version: '0.12.6');
    double? rate(String name) => options.tracesSampler!(SentrySamplingContext.forTransaction(SentryTransactionContext(name, name)));
    expect(rate(LinkReports.connectName), 1.0);
    expect(rate(LinkReports.linkName), 1.0);
    expect(rate('playback.open'), isNull);
    expect(options.tracesSampleRate, 0.1);
  });
}
