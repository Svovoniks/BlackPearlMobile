import 'package:material_ui/material_ui.dart';

import '../protocol/pair_link.dart';
import 'pebbles.dart';
import 'theme.dart';

/// Shown instead of the app when the paired PCs couldn't be read.
class StorageProblem extends StatelessWidget {
  const StorageProblem({super.key, required this.message, required this.busy, required this.onRetry});
  final String message;
  final bool busy;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Well(
                width: 96,
                height: 96,
                child: Center(child: Icon(Icons.lock_outline_rounded, size: 38, color: Palette.danger)),
              ),
              const SizedBox(height: 22),
              Text("Couldn't open your paired PCs", textAlign: TextAlign.center, style: display(24)),
              const SizedBox(height: 8),
              Text(
                '$message Try again. If it keeps happening, restart the phone.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Palette.muted, fontSize: 14.5, height: 1.4),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: 260,
                child: PebbleButton(
                  label: busy ? 'Trying…' : 'Try again',
                  icon: Icons.refresh_rounded,
                  lit: true,
                  onTap: busy ? null : onRetry,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Asks whether to convert a video whose file is already smaller than [quality] would be. Converting saves no data, but
/// the phone then plays the PC's H.264 rather than the file, which helps with a file the phone can't play well. It closes
/// by itself, answering no, once [offer] changes: another stream (a recovery, the next episode) ended the question.
Future<bool> confirmConvertAnyway(BuildContext context, String quality, {Listenable? offer}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => _ClosesOnChange(
      listenable: offer,
      child: AlertDialog(
        backgroundColor: Palette.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        // The player is usually sideways: a short screen with large text scrolls rather than cutting the buttons off.
        scrollable: true,
        title: Text('Convert anyway?', style: display(22)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "This file is already smaller than $quality would be, so converting it won't save data or play smoother on a "
              'slow connection.',
              style: const TextStyle(color: Palette.ink, fontWeight: FontWeight.w600, height: 1.4),
            ),
            const SizedBox(height: 8),
            const Text(
              'Convert it anyway if the phone has trouble with the file itself, such as a picture that freezes while the '
              'sound plays on. The PC converts it as you watch.',
              style: TextStyle(color: Palette.muted, height: 1.4),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actionsOverflowButtonSpacing: 8,
        actions: [
          Pebble(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            onTap: () => Navigator.of(context).pop(false),
            child: const Text('Play as it is'),
          ),
          Pebble(
            height: 42,
            lit: true,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            onTap: () => Navigator.of(context).pop(true),
            child: const Text('Convert anyway'),
          ),
        ],
      ),
    ),
  );
  return result == true;
}

/// Removes the dialog it is in, once [listenable] notifies.
class _ClosesOnChange extends StatefulWidget {
  const _ClosesOnChange({required this.listenable, required this.child});
  final Listenable? listenable;
  final Widget child;

  @override
  State<_ClosesOnChange> createState() => _ClosesOnChangeState();
}

class _ClosesOnChangeState extends State<_ClosesOnChange> {
  @override
  void initState() {
    super.initState();
    widget.listenable?.addListener(_changed);
  }

  @override
  void dispose() {
    widget.listenable?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    widget.listenable?.removeListener(_changed);
    final route = ModalRoute.of(context);
    if (mounted && route != null && route.isActive) Navigator.of(context).removeRoute(route);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The host part of a room server address, for showing where a link would send the phone.
String serverHost(String server) {
  final uri = Uri.tryParse(server.trim());
  final host = uri?.host ?? '';
  if (host.isEmpty) return server.trim();
  return uri!.hasPort ? '$host:${uri.port}' : host;
}

/// Asks before acting on a pairing link that came from outside the app (another app, a web page, the camera app):
/// pairing switches the remote to that PC.
Future<bool> confirmPairLink(BuildContext context, PairLink link) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: Palette.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text('Pair with ${link.name}?', style: display(22)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Through ${serverHost(link.server)}',
            style: const TextStyle(color: Palette.ink, fontWeight: FontWeight.w600, height: 1.4),
          ),
          const SizedBox(height: 8),
          const Text(
            'A link opened BlackPearl to pair this phone. Pair only if you just showed this code on your PC. '
            'The remote switches to that PC.',
            style: TextStyle(color: Palette.muted, height: 1.4),
          ),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        Pebble(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          onTap: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        Pebble(
          height: 42,
          lit: true,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          onTap: () => Navigator.of(context).pop(true),
          child: const Text('Pair'),
        ),
      ],
    ),
  );
  return result == true;
}
