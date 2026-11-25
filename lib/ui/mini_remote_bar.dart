import 'package:material_ui/material_ui.dart';

import '../connection/remote_link.dart';
import 'pebbles.dart';
import 'theme.dart';

/// What the PC plays, with its play buttons, for the screens that aren't the Remote: above the tab bar on Library and
/// Settings, and at the bottom of the pages that cover the tabs. A tap on the title opens the Remote.
class MiniRemoteBar extends StatelessWidget {
  const MiniRemoteBar({super.key, required this.link, required this.onOpen, this.safeBottom = true});
  final RemoteLink link;
  final VoidCallback onOpen;

  /// Whether the bar keeps clear of the system's navigation buttons itself; false above the tab bar, which does.
  final bool safeBottom;

  /// Whether there is anything to show: the PC is connected and plays a video.
  static bool shows(RemoteLink link) => link.status.isConnected && (link.state?.media ?? false);

  /// The bar for the Scaffold of a page above the tabs, or null while there is nothing to show: the page then keeps
  /// the bottom of the screen, and its inset, to itself.
  static Widget? forPage(RemoteLink link, VoidCallback? onOpen) =>
      onOpen != null && shows(link) ? MiniRemoteBar(link: link, onOpen: onOpen) : null;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: link,
    builder: (context, _) {
      final state = link.state;
      if (state == null || !shows(link)) return const SizedBox.shrink();
      final can = state.canControl;
      final title = state.title.isEmpty ? 'Untitled' : state.title;
      final where = '${state.playing ? 'Playing' : 'Paused'} on ${link.pcName}';
      Widget button(IconData icon, String label, VoidCallback onTap, {bool lit = false}) => Pebble(
        width: 40,
        height: 40,
        lit: lit,
        tapArea: Pebble.fingertip,
        enabled: can,
        onTap: onTap,
        semanticLabel: label,
        child: Icon(icon, size: 22),
      );
      return Material(
        color: Palette.surface,
        child: DecoratedBox(
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: Palette.elevated))),
          child: SafeArea(
            top: false,
            bottom: safeBottom,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              // Two lines of text beside 48 dp buttons: past 150% text they would outgrow the bar.
              child: MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.5,
                child: Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        button: true,
                        label: 'Open the remote. $title, $where',
                        excludeSemantics: true,
                        child: InkWell(
                          onTap: onOpen,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 48),
                            child: Column(
                              // As tall as its two lines: a page's Scaffold offers its bottom bar the whole screen.
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                                Text(where, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Palette.muted)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    button(Icons.replay_10_rounded, 'Back 10 seconds on the PC', () => link.command('seek-by', -10000)),
                    button(
                      state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      state.playing ? 'Pause the PC' : 'Play on the PC',
                      () => link.command('toggle'),
                      lit: true,
                    ),
                    button(Icons.forward_10_rounded, 'Forward 10 seconds on the PC', () => link.command('seek-by', 10000)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
