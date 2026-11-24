import 'package:blackpearl_mobile/diagnostics/crash_reports.dart';
import 'package:blackpearl_mobile/diagnostics/report_text.dart';
import 'package:blackpearl_mobile/storage/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

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

    test('a build without a DSN starts nothing', () async {
      expect(CrashReports.configured, isFalse);
      final settings = AppSettings(MemorySettingsStore());
      await CrashReports.start(settings);
      expect(Sentry.isEnabled, isFalse);
      final trace = PlaybackOpenTrace.start(kind: 'video', network: 'home');
      trace.opened();
    });

    test('the options keep personal data, breadcrumbs, screenshots, replays and logs out', () {
      final options = SentryFlutterOptions();
      CrashReports.configure(options, version: '0.8.2');
      expect(options.sendDefaultPii, isFalse);
      expect(options.maxBreadcrumbs, 0);
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
}
