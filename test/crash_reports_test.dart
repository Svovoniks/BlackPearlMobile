import 'dart:io';

import 'package:blackpearl_mobile/connection/remote_link.dart';
import 'package:blackpearl_mobile/diagnostics/crash_reports.dart';
import 'package:blackpearl_mobile/diagnostics/report_text.dart';
import 'package:blackpearl_mobile/diagnostics/trail.dart';
import 'package:blackpearl_mobile/storage/app_settings.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
// ignore: implementation_imports, depend_on_referenced_packages
import 'package:sentry/src/noop_hub.dart';
// ignore: implementation_imports, depend_on_referenced_packages
import 'package:sentry/src/telemetry/span/transaction/sentry_tracer.dart';

void main() {
  group('ReportText', () {
    test('replaces web addresses, with their queries', () {
      expect(ReportText.scrub('GET https://rooms.example.net:8443/remote?key=abc failed'), 'GET <url> failed');
      expect(ReportText.scrub('ws://10.0.0.5:47811/signal closed'), '<url> closed');
      expect(ReportText.scrub('Opening blackpearl://pair?v=1&s=x'), 'Opening <url>');
    });

    test('replaces Windows drive and network paths', () {
      expect(ReportText.scrub(r'Cannot open C:\Users\Anna\Videos\Some Film (2020).mkv'), 'Cannot open <path>');
      expect(ReportText.scrub('Cannot open d:/Movies/x.mp4'), 'Cannot open <path>');
      expect(ReportText.scrub(r'Read \\nas\share\Shows\Episode 1.mkv: denied'), 'Read <path>');
      expect(ReportText.scrub(r'Path "C:\Users\Anna\a.mkv" is missing'), 'Path "<path>" is missing');
    });

    test('replaces phone and unix paths', () {
      expect(ReportText.scrub('StateError reading /storage/emulated/0/Movies/Sample.mkv'), 'StateError reading <path>');
      expect(ReportText.scrub('at /data/user/0/io.github.svovoniks.blackpearlmobile/cache/x'), 'at <path>');
      expect(ReportText.scrub('No such file: /home/anna/Videos/a.mkv'), 'No such file: <path>');
      expect(ReportText.scrub('open /sdcard/Download/x.apk'), 'open <path>');
    });

    test('keeps slashes that are not home, storage or system folders', () {
      expect(ReportText.scrub('3/4 of the reads failed'), '3/4 of the reads failed');
      expect(
        ReportText.scrub('package:blackpearl_mobile/playback/phone_playback.dart'),
        'package:blackpearl_mobile/playback/phone_playback.dart',
      );
      // Only the listed top-level folders, as written: a word that merely contains one isn't a path.
      expect(ReportText.scrub('audio/media/x'), 'audio/media/x');
    });

    test('replaces network addresses', () {
      expect(ReportText.scrub('Connecting to 192.168.1.20:47811'), 'Connecting to <address>');
      expect(ReportText.scrub('peer 10.0.0.5 left'), 'peer <address> left');
      expect(ReportText.scrub('host fe80::1c2b:3a4d failed'), 'host <address> failed');
      expect(ReportText.scrub('candidate 2001:db8:85a3:0:0:8a2e:370:7334'), 'candidate <address>');
    });

    test('replaces long ids and keys', () {
      expect(ReportText.scrub('secret 0123456789abcdef0123456789abcdef'), 'secret <id>');
      expect(ReportText.scrub('phone 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08 unknown'), 'phone <id> unknown');
      expect(ReportText.scrub('token aGVsbG8td29ybGQtdGhpcy1pcy1hLWxvbmctdG9rZW4'), 'token <id>');
    });

    test('keeps times, versions, sizes and ordinary words', () {
      expect(ReportText.scrub('Stalled at 12:34:56 after 1:02'), 'Stalled at 12:34:56 after 1:02');
      expect(ReportText.scrub('BlackPearl Mobile 0.8.2+17 on Android 16'), 'BlackPearl Mobile 0.8.2+17 on Android 16');
      expect(ReportText.scrub('Read 1048576 bytes at offset 524288'), 'Read 1048576 bytes at offset 524288');
      expect(ReportText.scrub("The PC didn't answer. Try again."), "The PC didn't answer. Try again.");
      expect(ReportText.scrub(''), '');
    });

    test('a web address that holds a path is replaced once, as a web address', () {
      expect(ReportText.scrub('file:///C:/Users/anna/app/lib/main.dart'), '<url>');
    });
  });

  group('CrashReports', () {
    test('clears the user, the device and server names, and breadcrumbs, and scrubs errors', () {
      final event = SentryEvent(
        user: SentryUser(id: 'installation-1', ipAddress: '{{auto}}'),
        serverName: 'ANNAS-PC',
        breadcrumbs: [Breadcrumb(message: 'opened /storage/emulated/0/Movies/a.mkv')],
        message: SentryMessage('Failed on 10.0.0.5:47811', template: 'Failed on %s', params: ['10.0.0.5:47811']),
        exceptions: [
          SentryException(
            type: 'StateError',
            value: 'Bad state: Sentry test error 1 reading /storage/emulated/0/Movies/Sample.mkv',
            stackTrace: SentryStackTrace(frames: [SentryStackFrame(absPath: 'file:///C:/Users/anna/BlackPearlMobile/lib/main.dart')]),
          ),
        ],
        // As Android's contexts come in: the installation id is a key Dart's SentryDevice doesn't name.
        contexts: Contexts(
          device: SentryDevice.fromJson({
            'name': "Anna's phone",
            'id': '791c893d15264d349aca3768986bfa50',
            'model': 'Pixel 9',
            'simulator': false,
          }),
        ),
      );
      event.contexts['flutter_error_details'] = {'context': 'thrown building Text', 'information': 'Text("Some Film (2020)")'};

      final scrubbed = CrashReports.scrubEvent(event);

      expect(scrubbed.user, isNull);
      expect(scrubbed.serverName, isNull);
      expect(scrubbed.breadcrumbs, isNull);
      expect(scrubbed.contexts.device?.name, isNull);
      final device = scrubbed.contexts.device!.toJson();
      expect(device.containsKey('id'), isFalse);
      expect(device.containsKey('name'), isFalse);
      expect(device['model'], 'Pixel 9');
      expect(device['simulator'], isFalse);
      expect(scrubbed.message?.formatted, 'Failed on <address>');
      expect(scrubbed.message?.params, ['<address>']);
      expect(scrubbed.exceptions!.single.value, 'Bad state: Sentry test error 1 reading <path>');
      expect(scrubbed.exceptions!.single.type, 'StateError');
      expect(scrubbed.exceptions!.single.stackTrace!.frames.single.absPath, '<url>');
      expect(scrubbed.contexts['flutter_error_details'], {'context': 'thrown building Text'});
    });

    test("keeps only the kind of the PC's refusal, the first line of a FormatException, and no boot time or sizes", () {
      const refusal = RemoteRequestException('busy', 'Anna is playing the video Some Film (2020) in the room.');
      const badJson = FormatException('Unexpected character', '{"title":"Some Film (2020)"', 1);
      final event = SentryEvent(
        exceptions: [
          SentryException(type: 'RemoteRequestException', value: refusal.toString(), throwable: refusal),
          SentryException(type: 'FormatException', value: badJson.toString(), throwable: badJson),
        ],
        contexts: Contexts(
          device: SentryDevice.fromJson({
            'model': 'Pixel 9',
            'boot_time': '2026-11-24T08:12:59.267Z',
            'memory_size': 2592604160,
            'free_memory': 1180749824,
            'storage_size': 6228115456,
            'free_storage': 3600461824,
            'screen_dpi': 420,
          }),
        ),
      );
      expect(badJson.toString(), contains('Some Film'));

      final scrubbed = CrashReports.scrubEvent(event);

      expect(scrubbed.exceptions![0].value, 'The PC refused the request: busy');
      expect(scrubbed.exceptions![1].value, 'FormatException: Unexpected character (at character 2)');
      expect(scrubbed.contexts.device!.toJson(), {'model': 'Pixel 9', 'screen_dpi': 420});
    });

    test('a build without a DSN starts nothing', () async {
      expect(CrashReports.configured, isFalse);
      final settings = AppSettings(MemorySettingsStore());
      await CrashReports.start(settings);
      expect(Sentry.isEnabled, isFalse);
      final trace = PlaybackOpenTrace.start(kind: 'video', network: 'home');
      trace.opened();
    });

    test('the options keep personal data, screenshots, replays, logs and all but the app\'s own notes out', () {
      final options = SentryFlutterOptions();
      CrashReports.configure(options, version: '0.8.2');
      expect(options.sendDefaultPii, isFalse);
      expect(options.maxBreadcrumbs, 100);
      expect(options.enableAutoNativeBreadcrumbs, isFalse);
      expect(options.enableUserInteractionBreadcrumbs, isFalse);
      expect(options.enablePrintBreadcrumbs, isFalse);
      Breadcrumb? keep(Breadcrumb crumb) => options.beforeBreadcrumb!(crumb, Hint());
      final note = Breadcrumb(category: 'link', message: 'connected');
      Trail.enabled = true;
      expect(keep(note), same(note));
      expect(keep(Breadcrumb.http(url: Uri.parse('https://rooms.example.com/remote'), method: 'GET')), isNull);
      expect(keep(Breadcrumb(category: 'navigation', message: 'Library')), isNull);
      expect(keep(Breadcrumb(category: 'console', message: 'print')), isNull);
      expect(keep(Breadcrumb(message: 'no category')), isNull);
      Trail.enabled = false;
      expect(keep(note), isNull, reason: 'the log is off');
      expect(options.attachScreenshot, isFalse);
      expect(options.attachViewHierarchy, isFalse);
      expect(options.replay.sessionSampleRate, 0);
      expect(options.replay.onErrorSampleRate, 0);
      expect(options.enableUserInteractionTracing, isFalse);
      expect(options.enableAutoSessionTracking, isFalse);
      expect(options.release, 'blackpearl-mobile@0.8.2');
      expect(options.environment, 'production');
      expect(options.tracesSampleRate, 0.1);
      expect(options.traceLifecycle, SentryTraceLifecycle.static);
    });

    test("a report keeps the app's own notes, scrubbed again, and no other breadcrumbs", () {
      final event = SentryEvent(
        breadcrumbs: [
          Breadcrumb(category: 'link', message: 'failed', data: {'why': 'no-answer', 'failures': 3}),
          // Written by mistake with an address in it: scrubbed as error text is.
          Breadcrumb(category: 'playback', message: 'opening 10.0.0.5:47811', data: {'from': '/storage/emulated/0/Movies/a.mkv'}),
          Breadcrumb.http(url: Uri.parse('https://rooms.example.com/remote'), method: 'GET'),
          Breadcrumb(category: 'navigation', message: 'Some Film (2020)'),
        ],
      );
      final original = event.breadcrumbs![1];
      final kept = CrashReports.scrubEvent(event).breadcrumbs!;
      expect(kept.map((c) => c.category), ['link', 'playback']);
      expect(kept[0].data, {'why': 'no-answer', 'failures': 3});
      expect(kept[1].message, 'opening <address>');
      expect(kept[1].data, {'from': '<path>'});
      expect(kept[1].timestamp, original.timestamp);
      expect(original.message, 'opening 10.0.0.5:47811', reason: "the scope's own note isn't rewritten");
    });

    test('a timing carries no notes', () {
      final transaction = SentryTransaction(SentryTracer(SentryTransactionContext('playback.open', 'playback'), NoOpHub()))
        ..breadcrumbs = [Breadcrumb(category: 'link', message: 'connected')];
      expect(CrashReports.scrubTransaction(transaction).breadcrumbs, isNull);
    });

    test("the Android SDK's network breadcrumbs, which enableAutoNativeBreadcrumbs leaves on, are off", () {
      final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(
        RegExp(r'android:name="io\.sentry\.breadcrumbs\.network-events"\s+android:value="false"').hasMatch(manifest),
        isTrue,
      );
    });

    // Last in the group: from here on CrashReports follows these settings.
    test("with the app's log off, or crash reports off, reports carry no notes and none are kept", () async {
      final store = MemorySettingsStore();
      final settings = AppSettings(store);
      await settings.load();
      CrashReports.follow(settings);
      expect(Trail.enabled, isTrue);
      SentryEvent withNote() => SentryEvent(breadcrumbs: [Breadcrumb(category: 'link', message: 'connected')]);
      expect(CrashReports.scrubEvent(withNote()).breadcrumbs, hasLength(1));

      await settings.setAppLog(false);
      expect(Trail.enabled, isFalse);
      expect(Trail.keeps(Breadcrumb(category: 'link', message: 'connected')), isFalse);
      expect(CrashReports.scrubEvent(withNote()).breadcrumbs, isNull);

      await settings.setAppLog(true);
      expect(Trail.enabled, isTrue);

      final off = AppSettings(MemorySettingsStore());
      await off.load();
      await off.setCrashReports(false);
      CrashReports.follow(off);
      expect(Trail.enabled, isFalse, reason: 'the log rides on crash reports');
      Trail.reset();
    });
  });

  group('Trail', () {
    tearDown(Trail.reset);

    test('the same problem is reported once every half hour, and at most 20 in a run of the app', () {
      fakeAsync((async) {
        Trail.reset();
        final reported = Trail.recorded = [];
        Trail.problem('link', 'no-answer');
        Trail.problem('link', 'no-answer');
        expect(reported, hasLength(1));
        Trail.problem('update', 'installer');
        expect(reported, hasLength(2));
        async.elapse(const Duration(minutes: 29));
        Trail.problem('link', 'no-answer');
        expect(reported, hasLength(2));
        async.elapse(const Duration(minutes: 1));
        Trail.problem('link', 'no-answer');
        expect(reported, hasLength(3));
        for (var i = 0; i < 30; i++) {
          Trail.problem('link', 'other-$i');
        }
        expect(reported, hasLength(Trail.problemLimit));
      });
    });

    test('opening a video is noted with how, never what', () {
      final notes = Trail.recorded = [];
      PlaybackOpenTrace.start(kind: 'episode', network: 'away')
        ..opened()
        ..failed();
      PlaybackOpenTrace.start(kind: 'video', network: 'home').cancelled();
      expect(notes.map((n) => n.message), ['opening', 'showing', 'opening', 'opening stopped']);
      expect(notes.first.data, {'kind': 'episode', 'network': 'away'});
    });
  });

  test('crash reports are on until turned off, and the choice is kept', () async {
    final store = MemorySettingsStore();
    final settings = AppSettings(store);
    await settings.load();
    expect(settings.crashReports, isTrue);
    await settings.setCrashReports(false);
    final again = AppSettings(store);
    await again.load();
    expect(again.crashReports, isFalse);
  });

  test("the app's log is on until turned off, and the choice is kept", () async {
    final store = MemorySettingsStore();
    final settings = AppSettings(store);
    await settings.load();
    expect(settings.appLog, isTrue);
    await settings.setAppLog(false);
    final again = AppSettings(store);
    await again.load();
    expect(again.appLog, isFalse);
    expect(again.crashReports, isTrue);
  });
}
