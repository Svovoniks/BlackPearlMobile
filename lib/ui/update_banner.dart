import 'package:material_ui/material_ui.dart';

import '../update/app_update.dart';
import 'pebbles.dart';
import 'theme.dart';

/// Puts the update banner above [child] while there is an update to offer. The child then starts below it, so the
/// banner takes the status bar's space instead of the screen's own top edge.
class UpdateFrame extends StatelessWidget {
  const UpdateFrame({super.key, required this.updater, required this.child});
  final AppUpdater? updater;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final updater = this.updater;
    if (updater == null) return child;
    return ListenableBuilder(
      listenable: updater,
      child: child,
      builder: (context, screen) {
        final show = updater.showBanner;
        // The same widgets with or without the banner, and the screen keyed, so it keeps its state when the banner
        // comes and goes.
        // The banner sits outside the screen's Scaffold, so this Material gives it the app's text style.
        return Material(
          color: Palette.canvas,
          child: Column(
            children: [
              if (show)
                SafeArea(
                  key: const ValueKey('update-banner'),
                  bottom: false,
                  child: Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0), child: UpdateBanner(updater: updater)),
                ),
              Expanded(
                key: const ValueKey('screen'),
                child: MediaQuery.removePadding(context: context, removeTop: show, child: screen!),
              ),
            ],
          ),
        );
      },
    );
  }
}

class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.updater});
  final AppUpdater updater;

  @override
  Widget build(BuildContext context) {
    final version = updater.release?.version ?? '';
    final percent = (updater.progress * 100).floor();
    final (title, detail, action, onAction) = switch (updater.phase) {
      UpdatePhase.available => ('Update available', 'BlackPearl Mobile $version', 'Update', updater.update),
      UpdatePhase.needsPermission => (
        'Allow updates',
        'Turn on “Allow from this source” for BlackPearl, then come back.',
        'Settings',
        updater.update,
      ),
      UpdatePhase.downloading => ('Downloading $version', '$percent%', null, null),
      UpdatePhase.ready => ('Install $version', 'Confirm in the Android prompt.', 'Install', updater.update),
      UpdatePhase.failed => ("Update didn't finish", updater.error ?? 'Try again.', 'Retry', updater.update),
      UpdatePhase.none => ('', '', null, null),
    };
    final downloading = updater.phase == UpdatePhase.downloading;
    final failed = updater.phase == UpdatePhase.failed;
    return Semantics(
      container: true,
      child: Slab(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Row(
          children: [
            Icon(
              failed ? Icons.error_outline_rounded : Icons.system_update_rounded,
              size: 22,
              color: failed ? Palette.danger : Palette.accent,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Only the title is announced as it changes; not each percent of a download.
                  Semantics(
                    liveRegion: true,
                    child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  ),
                  const SizedBox(height: 1),
                  Text(detail, style: const TextStyle(color: Palette.muted, fontSize: 12.5, height: 1.3)),
                  if (downloading) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: updater.progress,
                        minHeight: 4,
                        color: Palette.accent,
                        backgroundColor: Palette.well,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (action != null) ...[
              const SizedBox(width: 10),
              Pebble(
                height: 34,
                lit: !failed,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                onTap: onAction,
                child: Text(action, style: const TextStyle(fontSize: 13)),
              ),
            ],
            if (downloading)
              const SizedBox(width: 8)
            else
              IconButton(
                onPressed: updater.dismiss,
                tooltip: 'Not now',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded, size: 20, color: Palette.muted),
              ),
          ],
        ),
      ),
    );
  }
}
