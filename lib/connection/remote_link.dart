import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../protocol/remote_state.dart';
import 'media_channel.dart';
import 'transport.dart';

enum LinkPhase {
  /// Opening the room server connection.
  connecting,

  /// The room server says the PC isn't connected to it.
  waitingForPc,

  /// The PC is online; setting up the direct link.
  linking,

  /// Pairing with a code: the link is up and the phone is asking to be paired.
  pairing,

  /// Commands and state flow.
  connected,

  /// Something went wrong. [LinkStatus.retryAt] says when the next attempt starts, if any.
  failed,

  /// Not trying (the app is in the background, or nothing is selected).
  idle,
}

@immutable
class LinkStatus {
  const LinkStatus(this.phase, {this.message, this.path = NetworkPath.unknown, this.retryAt, this.needsPairing = false});

  final LinkPhase phase;

  /// A sentence explaining a failure, from the protocol where it gives one.
  final String? message;
  final NetworkPath path;

  /// When the next automatic attempt starts. Null for a failure that needs the user.
  final DateTime? retryAt;

  /// The failure can only be fixed by pairing again.
  final bool needsPairing;

  bool get isConnected => phase == LinkPhase.connected;
}

/// The PC refused a request (its `error` message with the request's number), or the link went before it answered.
class RemoteRequestException implements Exception {
  const RemoteRequestException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

/// What the screens talk to: the real connection, or a stand-in for previews and tests.
abstract class RemoteLink extends ChangeNotifier {
  String get pcName;
  LinkStatus get status;

  /// The last state the PC sent, kept while reconnecting so the screen doesn't blank out.
  RemoteState? get state;

  /// When [state] arrived, for advancing the position locally.
  DateTime? get stateReceivedAt;

  /// A short-lived message for a command the PC couldn't do (its `error` message).
  ValueListenable<String?> get notice;

  void command(String action, [Object? value]);

  /// Starts a new attempt now instead of waiting for the retry timer.
  void retryNow();

  /// What the PC offers beyond the remote, from its welcome: `library`, `watch`.
  Set<String> get features => const {};

  /// Whether the PC lets phones start videos on it.
  bool get canStart => true;

  /// Reads video and picture bytes, while the link and its media channel are up.
  MediaReader? get media => null;

  /// Sends a request and waits for the PC's answer with the same number (`page`, `stream`), or its `error`.
  Future<Map<String, dynamic>> ask(String type, Map<String, dynamic> fields, {Duration timeout = const Duration(seconds: 20)}) =>
      Future.error(const RemoteRequestException('offline', "The PC isn't connected."));

  /// Sends a message that needs no answer (`progress`, `stream-stop`).
  void tell(String type, Map<String, dynamic> fields) {}

  /// Completes once no request waits for its answer, or after [limit]. The PC's answers travel behind the video it
  /// sends, and wait there until the video already on its way has gone: the phone's player holds its next reads back
  /// meanwhile.
  Future<void> answered(Duration limit) => Future.value();

  /// The position the player is at now, advanced from [stateReceivedAt] while playing.
  int currentPositionMs() {
    final current = state;
    final at = stateReceivedAt;
    if (current == null) return 0;
    if (at == null) return current.positionMs;
    return current.positionAfter(clock.now().difference(at).inMilliseconds);
  }
}
