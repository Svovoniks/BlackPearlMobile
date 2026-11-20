import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../protocol/remote_state.dart';
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

/// What the Remote screen talks to: the real connection, or a stand-in for previews and tests.
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

  /// The position the player is at now, advanced from [stateReceivedAt] while playing.
  int currentPositionMs() {
    final current = state;
    final at = stateReceivedAt;
    if (current == null) return 0;
    if (at == null) return current.positionMs;
    return current.positionAfter(clock.now().difference(at).inMilliseconds);
  }
}
