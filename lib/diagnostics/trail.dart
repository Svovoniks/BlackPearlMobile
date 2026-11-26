import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'report_text.dart';

/// The app's log: short notes of what it just did (connecting to the PC, opening a video, updating), which Sentry keeps
/// on the phone and sends with the next crash report, and reports of failures that aren't crashes, such as a link to
/// the PC that keeps failing. Only while Settings › Send crash reports and Send the app's log are both on.
///
/// Notes are the app's own words and fixed codes. Never put in a title, a name, an address, a path or anything the PC or
/// a server said: those stay out even though the text is scrubbed again before it is sent.
abstract final class Trail {
  /// The categories the app writes. Anything else Sentry would add on its own (web requests, screens, taps, the
  /// console) is dropped.
  static const categories = {'link', 'playback', 'update'};

  /// Set by [CrashReports]: whether notes are kept and problems reported.
  static bool enabled = false;

  /// For tests: notes and problems go here instead of to Sentry, whether or not [enabled].
  @visibleForTesting
  static List<Breadcrumb>? recorded;

  /// How often the same problem is reported, and how many are reported in one run of the app at most. A link that fails
  /// over and over is one report, with the notes that led to it.
  static const problemInterval = Duration(minutes: 30);
  static const problemLimit = 20;
  static final Map<String, DateTime> _reportedAt = {};
  static int _reported = 0;

  /// A note: [category] is one of [categories]; [message] and [data]'s strings are fixed text written in the app.
  static void note(String category, String message, [Map<String, Object>? data]) {
    assert(categories.contains(category), 'Unknown trail category $category');
    final crumb = Breadcrumb(category: category, message: message, data: data);
    final test = recorded;
    if (test != null) {
      test.add(crumb);
      return;
    }
    if (!enabled) return;
    unawaited(Sentry.addBreadcrumb(crumb).catchError((Object _) {}));
  }

  /// A failure that isn't a crash, sent as a warning with the notes before it; [reason] is a fixed code that groups
  /// reports. The same one goes at most once every [problemInterval].
  static void problem(String category, String reason, [Map<String, Object>? data]) {
    assert(categories.contains(category), 'Unknown trail category $category');
    final test = recorded;
    if (test == null && !enabled) return;
    final key = '$category/$reason', now = clock.now();
    final last = _reportedAt[key];
    if (last != null && now.difference(last) < problemInterval) return;
    if (_reported >= problemLimit) return;
    _reportedAt[key] = now;
    _reported++;
    if (test != null) {
      test.add(Breadcrumb(category: category, message: 'problem: $reason', data: data, level: SentryLevel.warning));
      return;
    }
    unawaited(
      Sentry.captureMessage(
        '$category: $reason',
        level: SentryLevel.warning,
        withScope: (scope) async {
          scope.fingerprint = ['trail', category, reason];
          await scope.setTag('trail.$category', reason);
          if (data != null) await scope.setContexts('trail', _scrubData(data));
        },
      ).catchError((Object _) => SentryId.empty()),
    );
  }

  /// Forgets which problems were reported; for tests.
  @visibleForTesting
  static void reset() {
    _reportedAt.clear();
    _reported = 0;
    recorded = null;
    enabled = false;
  }

  /// Whether Sentry may keep [crumb]: one of the app's own, while the log is on.
  static bool keeps(Breadcrumb crumb) => enabled && categories.contains(crumb.category);

  /// The notes [breadcrumbs] holds, scrubbed as error text is, as copies: the scope's own stay as written. Null when none
  /// is left.
  static List<Breadcrumb>? scrubbed(List<Breadcrumb>? breadcrumbs) {
    final kept = [
      for (final crumb in breadcrumbs ?? const <Breadcrumb>[])
        if (categories.contains(crumb.category))
          Breadcrumb(
            message: ReportText.scrubOrNull(crumb.message),
            timestamp: crumb.timestamp,
            category: crumb.category,
            data: crumb.data == null ? null : _scrubData(crumb.data!),
            level: crumb.level,
            type: crumb.type,
          ),
    ];
    return kept.isEmpty ? null : kept;
  }

  static Map<String, dynamic> _scrubData(Map<String, dynamic> data) =>
      data.map((key, value) => MapEntry(key, value is String ? ReportText.scrub(value) : value));
}
