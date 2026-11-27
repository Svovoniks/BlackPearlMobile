import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// A timing of the link to the PC (PHONE-REMOTE.md, "Measuring the link"), made once what it measures has ended: how a
/// link was set up ([LinkReports.connectName]), or a stretch of a link that was up ([LinkReports.linkName]). It holds
/// fixed codes, kinds and numbers only: never an id, a name, an address or what was read.
@immutable
class LinkReport {
  const LinkReport({
    required this.name,
    required this.start,
    required this.end,
    this.status = 'ok',
    this.tags = const {},
    this.measurements = const {},
    this.stages = const [],
  });

  final String name;
  final DateTime start, end;

  /// `ok`, `unavailable` (the link failed), `deadline_exceeded` (something didn't answer in time) or `aborted`.
  final String status;
  final Map<String, String> tags;

  /// Values with their units: `ms`, `byte`, or none.
  final Map<String, (num, String)> measurements;

  /// The setup's stages in order: their name, start and end.
  final List<(String, DateTime, DateTime)> stages;
}

/// Where [LinkReport]s go: to Sentry while crash reports are on. Each one goes, unlike other timings (see
/// `CrashReports.configure`): a phone links up a few times a day.
abstract final class LinkReports {
  static const connectName = 'remote.connect', linkName = 'remote.link';

  /// A link that stays up is reported in stretches this long.
  static const window = Duration(minutes: 10);

  /// A ping unanswered this long counts as unanswered; an answer after it counts for nothing.
  static const pongWait = Duration(seconds: 10);

  /// Sentry keeps at most this many measurements of a transaction.
  static const measurementLimit = 10;

  /// How often the same failed setup is reported: a link that keeps failing is one report per half hour.
  static const failureInterval = Duration(minutes: 30);
  static final Map<String, DateTime> _failedAt = {};

  /// For tests: reports go here instead of to Sentry.
  @visibleForTesting
  static List<LinkReport>? recorded;

  @visibleForTesting
  static void reset() {
    recorded = null;
    _failedAt.clear();
  }

  /// Whether a setup that failed for [why] may be reported now.
  static bool mayReportFailure(String why, DateTime now) {
    final last = _failedAt[why];
    if (last != null && now.difference(last) < failureInterval) return false;
    _failedAt[why] = now;
    return true;
  }

  /// A version as an app gives it, or `other` for anything that doesn't look like one.
  static String? version(Object? text) {
    if (text is! String) return null;
    return RegExp(r'^[0-9A-Za-z][0-9A-Za-z.+\-]{0,39}$').hasMatch(text) ? text : 'other';
  }

  static void send(LinkReport report) {
    final test = recorded;
    if (test != null) {
      test.add(report);
      return;
    }
    if (!Sentry.isEnabled) return;
    try {
      final transaction = Sentry.startTransaction(report.name, report.name, startTimestamp: report.start, bindToScope: false);
      report.tags.forEach(transaction.setTag);
      report.measurements.forEach((name, measurement) {
        final (value, unit) = measurement;
        transaction.setMeasurement(name, value, unit: switch (unit) {
          'ms' => DurationSentryMeasurementUnit.milliSecond,
          'byte' => InformationSentryMeasurementUnit.byte,
          _ => SentryMeasurementUnit.none,
        });
      });
      for (final (stage, start, end) in report.stages) {
        final span = transaction.startChild('${report.name}.stage', description: stage, startTimestamp: start);
        unawaited(span.finish(status: const SpanStatus.ok(), endTimestamp: end).catchError((Object _) {}));
      }
      unawaited(transaction.finish(status: _status(report.status), endTimestamp: report.end).catchError((Object _) {}));
    } catch (_) {}
  }

  static SpanStatus _status(String status) => switch (status) {
    'ok' => const SpanStatus.ok(),
    'unavailable' => const SpanStatus.unavailable(),
    'deadline_exceeded' => const SpanStatus.deadlineExceeded(),
    'failed_precondition' => const SpanStatus.failedPrecondition(),
    _ => const SpanStatus.aborted(),
  };
}

/// The round trips of the phone's pings to the PC (PHONE-REMOTE.md, "Checking the link") since a stretch began.
class LinkStats {
  LinkStats(this.started);

  DateTime started;
  final Map<int, DateTime> _waiting = {};
  final List<double> _rtts = [];
  int _pings = 0, _pongs = 0, _unanswered = 0;

  void pingSent(int number, DateTime at) {
    _expire(at);
    _pings++;
    _waiting[number] = at;
  }

  /// The PC's pong: whether it answered a ping still waiting.
  bool pong(int number, DateTime at) {
    final sent = _waiting.remove(number);
    if (sent == null) return false;
    final elapsed = at.difference(sent);
    if (elapsed > LinkReports.pongWait) {
      _unanswered++;
      return false;
    }
    _pongs++;
    if (_rtts.length < 4096) _rtts.add(elapsed.inMicroseconds / 1000);
    return true;
  }

  void _expire(DateTime now) {
    _waiting.removeWhere((_, sent) {
      final late = now.difference(sent) > LinkReports.pongWait;
      if (late) _unanswered++;
      return late;
    });
  }

  /// The stretch so far with what the media channel did in it, and a new one from [now]. Pings still waiting carry over.
  LinkWindow take(DateTime now, MediaUse media) {
    _expire(now);
    final window = LinkWindow(
      start: started,
      end: now,
      pings: _pings,
      pongs: _pongs,
      unanswered: _unanswered,
      rttMedian: percentile(_rtts, 0.5),
      rttP90: percentile(_rtts, 0.9),
      rttMax: _rtts.isEmpty ? null : _rtts.reduce((a, b) => a > b ? a : b),
      media: media,
    );
    _rtts.clear();
    _pings = _pongs = _unanswered = 0;
    started = now;
    return window;
  }

  /// Nearest rank: the median of 1, 2, 3, 4 is 2, and the 90th percentile of ten samples their ninth.
  static double? percentile(List<double> samples, double fraction) {
    if (samples.isEmpty) return null;
    final sorted = [...samples]..sort();
    final index = ((fraction * sorted.length).ceil() - 1).clamp(0, sorted.length - 1);
    return (sorted[index] * 10).round() / 10;
  }
}

/// What the media channel did in a stretch: its bytes, the reads it finished, how long reads were in flight at all, and
/// how long each waited for its first frame.
@immutable
class MediaUse {
  const MediaUse({this.bytes = 0, this.reads = 0, this.busy = Duration.zero, this.firstBytes = const []});
  static const none = MediaUse();
  final int bytes, reads;
  final Duration busy;
  final List<double> firstBytes;

  /// Kilobits a second while reads were in flight, which is how fast the link delivers while the phone wants video: only
  /// once there is enough to tell (half a second of reading, 64 KiB).
  double? get kbps => busy.inMilliseconds >= 500 && bytes >= 65536 ? (bytes * 8 / busy.inMicroseconds * 1000).roundToDouble() : null;
}

@immutable
class LinkWindow {
  const LinkWindow({
    required this.start,
    required this.end,
    required this.pings,
    required this.pongs,
    required this.unanswered,
    required this.rttMedian,
    required this.rttP90,
    required this.rttMax,
    required this.media,
  });

  final DateTime start, end;
  final int pings, pongs, unanswered;
  final double? rttMedian, rttP90, rttMax;
  final MediaUse media;

  /// Something answered or was read: a locked phone's silent link says nothing about the link.
  bool get measured => pongs > 0 || media.reads > 0;

  /// At most [LinkReports.measurementLimit]; a number nothing measured is left out.
  Map<String, (num, String)> get measurements => {
    if (rttMedian case final v?) 'rtt': (v, 'ms'),
    if (rttP90 case final v?) 'rtt_p90': (v, 'ms'),
    if (rttMax case final v?) 'rtt_max': (v, 'ms'),
    'pings': (pings, ''),
    'pings_unanswered': (unanswered, ''),
    'media_bytes': (media.bytes, 'byte'),
    'media_reads': (media.reads, ''),
    if (media.kbps case final v?) 'media_kbps': (v, ''),
    if (LinkStats.percentile(media.firstBytes, 0.5) case final v?) 'first_byte': (v, 'ms'),
    if (LinkStats.percentile(media.firstBytes, 0.9) case final v?) 'first_byte_p90': (v, 'ms'),
  };
}
