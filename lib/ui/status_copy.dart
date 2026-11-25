import 'package:material_ui/material_ui.dart';

import '../connection/remote_link.dart';

class StatusCopy {
  const StatusCopy(this.headline, this.detail, this.icon, {this.shortDetail});
  final String headline;
  final String detail;
  final String? shortDetail;
  final IconData icon;
}

/// The words for each connection state.
StatusCopy describe(LinkStatus status, String pcName) => switch (status.phase) {
  LinkPhase.connecting => StatusCopy(
    'Connecting…',
    'Reaching the room server that introduces this phone to $pcName.',
    Icons.cloud_outlined,
  ),
  LinkPhase.linking => StatusCopy('Reaching $pcName…', 'Setting up a direct, encrypted link to the PC.', Icons.link_rounded),
  LinkPhase.pairing => StatusCopy('Pairing with $pcName…', 'The PC is adding this phone.', Icons.link_rounded),
  LinkPhase.waitingForPc => StatusCopy(
    "Your PC isn't online",
    'Open BlackPearl on $pcName and turn on Phone remote in Settings › Profile. This connects as soon as the PC is back.',
    Icons.desktop_access_disabled_outlined,
    shortDetail: 'Connects as soon as the PC is back.',
  ),
  LinkPhase.failed => StatusCopy(
    status.message ?? "Couldn't connect",
    status.needsPairing ? 'Show a new pairing code on the PC and scan it.' : '',
    status.needsPairing ? Icons.link_off_rounded : Icons.error_outline_rounded,
  ),
  LinkPhase.idle => StatusCopy('Not connected', 'The remote reconnects when you come back to the app.', Icons.pause_circle_outline_rounded),
  LinkPhase.connected => StatusCopy('Connected', '', Icons.check_circle_outline_rounded),
};
