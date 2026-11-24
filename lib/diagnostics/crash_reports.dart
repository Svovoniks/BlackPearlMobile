import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../storage/app_settings.dart';
import 'report_text.dart';

/// Errors, crashes and how long startup and opening videos take, sent to BlackPearl's developer through Sentry unless
/// Settings › Send crash reports is off. Nothing names the user: file paths, titles, network and web addresses, names
/// and ids are removed first, and there are no breadcrumbs, screenshots, replays or logs.
///
/// A build without `--dart-define=SENTRY_DSN=…` (a local build, the tests) sends nothing and doesn't start Sentry.
abstract final class CrashReports {
  static const dsn = String.fromEnvironment('SENTRY_DSN');
  static const environment = String.fromEnvironment('SENTRY_ENVIRONMENT', defaultValue: 'production');

  /// Whether this build has somewhere to send reports.
  static bool get configured => dsn.isNotEmpty;

  static AppSettings? _settings;
  static bool _running = false;
  static String? _version;
  // Turning the setting off and on again quickly: each change waits for the one before.
  static Future<void> _switching = Future.value();

  /// The first thing in `main`: Flutter's binding, with Sentry's timing of frames and of startup where this build sends
  /// reports.
  static void ensureBinding() {
    if (configured) {
      SentryWidgetsFlutterBinding.ensureInitialized();
    } else {
      WidgetsFlutterBinding.ensureInitialized();
    }
  }

  /// Starts Sentry, unless this build has no DSN or the user turned crash reports off, and from then on follows the
  /// setting: off closes Sentry (on Android its native side too), on starts it again. Call it once [settings] is loaded
  /// and before `runApp`, so startup is measured and nothing is sent when the setting is off.
  static Future<void> start(AppSettings settings) async {
    if (!configured) return;
    _settings = settings;
    settings.addListener(_settingChanged);
    _running = settings.crashReports;
    if (_running) await _init();
  }

  static void _settingChanged() {
    final wanted = _settings?.crashReports ?? false;
    if (wanted == _running) return;
    _running = wanted;
    _switching = _switching.then((_) => wanted ? _init() : Sentry.close()).catchError((Object _) {});
  }

  static Future<void> _init() async {
    final version = _version ??= await _appVersion();
    await SentryFlutter.init((options) => configure(options, version: version));
  }

  static Future<String> _appVersion() async {
    try {
      return (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return '0.0.0';
    }
  }

  @visibleForTesting
  static void configure(SentryFlutterOptions options, {required String version}) {
    options
      ..dsn = dsn
      ..environment = environment
      // PackageInfo's version is pubspec's without the build number.
      ..release = 'blackpearl-mobile@$version'
      ..tracesSampleRate = environment == 'production' ? 0.1 : 1.0
      // Whole transactions rather than streamed spans, so beforeSendTransaction sees them.
      ..traceLifecycle = SentryTraceLifecycle.static
      ..sendDefaultPii = false
      ..maxBreadcrumbs = 0
      ..enableAutoNativeBreadcrumbs = false
      ..enableUserInteractionBreadcrumbs = false
      ..enablePrintBreadcrumbs = false
      // Its transactions are named after widget keys, which can hold titles.
      ..enableUserInteractionTracing = false
      // Sessions carry an id for the installation.
      ..enableAutoSessionTracking = false
      ..attachScreenshot = false
      ..attachViewHierarchy = false
      ..beforeBreadcrumb = ((_, _) => null)
      ..beforeSend = ((event, _) => _sending ? scrubEvent(event) : null)
      ..beforeSendTransaction = ((transaction, _) => _sending ? scrubTransaction(transaction) : null)
      ..beforeSendLog = ((_, _) => null)
      ..beforeSendMetric = ((_, _) => null);
    options.replay
      ..sessionSampleRate = 0
      ..onErrorSampleRate = 0;
  }

  // Off in Settings: nothing more goes, even before Sentry has closed.
  static bool get _sending => _settings?.crashReports ?? true;

  /// Takes what could name the user or their library out of an error before it is sent.
  @visibleForTesting
  static SentryEvent scrubEvent(SentryEvent event) {
    event
      ..user = null
      ..serverName = null
      ..breadcrumbs = null
      ..request = null
      ..transaction = ReportText.scrubOrNull(event.transaction)
      ..culprit = ReportText.scrubOrNull(event.culprit);
    // The device's name, and the id Sentry's Android SDK gives the installation (which Dart keeps among unknown keys).
    final device = event.contexts.device;
    if (device != null) {
      event.contexts.device = SentryDevice.fromJson(
        device.toJson()
          ..remove('name')
          ..remove('id'),
      );
    }
    final message = event.message;
    if (message != null) {
      message
        ..formatted = ReportText.scrub(message.formatted)
        ..template = ReportText.scrubOrNull(message.template)
        ..params = message.params?.map((p) => p is String ? ReportText.scrub(p) : p).toList();
    }
    for (final exception in event.exceptions ?? const <SentryException>[]) {
      exception.value = ReportText.scrubOrNull(exception.value);
      _scrubFrames(exception.stackTrace);
    }
    for (final thread in event.threads ?? const <SentryThread>[]) {
      _scrubFrames(thread.stacktrace);
    }
    // Flutter's own errors: where it was thrown stays, scrubbed; the widget descriptions after it can quote text on screen.
    final details = event.contexts['flutter_error_details'];
    if (details is Map) {
      event.contexts['flutter_error_details'] = {if (details['context'] case final String context) 'context': ReportText.scrub(context)};
    }
    return event;
  }

  /// The same for a transaction (app start, opening a video), and its spans' descriptions.
  @visibleForTesting
  static SentryTransaction scrubTransaction(SentryTransaction transaction) {
    scrubEvent(transaction);
    for (final span in transaction.spans) {
      span.context.description = ReportText.scrubOrNull(span.context.description);
    }
    return transaction;
  }

  static void _scrubFrames(SentryStackTrace? stackTrace) {
    // A debug build's frames name files on the developer's PC; a release build's are package: URIs.
    for (final frame in stackTrace?.frames ?? const <SentryStackFrame>[]) {
      frame
        ..absPath = ReportText.scrubOrNull(frame.absPath)
        ..fileName = ReportText.scrubOrNull(frame.fileName);
    }
  }
}

/// How long a video takes to open on the phone: from the request to play it until the player shows it (`ok`), it
/// fails (`internal_error`), something else replaces it (`cancelled`), or nothing happens for two minutes
/// (`deadline_exceeded`). It carries how it was opened, never what.
class PlaybackOpenTrace {
  PlaybackOpenTrace._(this._span) {
    if (_span != null) _deadline = Timer(const Duration(minutes: 2), () => _finish(const SpanStatus.deadlineExceeded()));
  }

  /// [kind]: `video` (a new one), `episode` (another in the same player), `quality` (another stream of the video on
  /// screen) or `recovery`; [network]: `home`, `away` or `relayed`.
  factory PlaybackOpenTrace.start({required String kind, required String network}) {
    if (!Sentry.isEnabled) return PlaybackOpenTrace._(null);
    final span = Sentry.startTransaction('playback.open', 'playback', bindToScope: false)
      ..setTag('playback.kind', kind)
      ..setTag('network', network);
    return PlaybackOpenTrace._(span);
  }

  ISentrySpan? _span;
  Timer? _deadline;

  void opened() => _finish(const SpanStatus.ok());
  void failed() => _finish(const SpanStatus.internalError());
  void cancelled() => _finish(const SpanStatus.cancelled());

  void _finish(SpanStatus status) {
    _deadline?.cancel();
    final span = _span;
    if (span == null) return;
    _span = null;
    unawaited(span.finish(status: status).catchError((Object _) {}));
  }
}
