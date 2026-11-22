import 'package:material_ui/material_ui.dart';

import '../protocol/remote_state.dart' show formatClock;
import 'pebbles.dart';
import 'theme.dart';

/// The chips in the dock, each opening its own short menu.
enum DockMenu { audio, subtitles, quality }

/// What a chip shows: the track or quality playing now.
class DockChipValue {
  const DockChipValue(this.label, {this.busy = false, this.off = false});
  final String label;

  /// Waiting for it to change, such as another quality.
  final bool busy;

  /// Nothing chosen, such as subtitles turned off: the label is muted.
  final bool off;
}

/// The player's controls at the bottom, on one dark slab: the timeline, playback in the middle, and chips that show the
/// audio, subtitles and quality playing now. In landscape it is two rows; in portrait the chips and the other buttons get
/// rows of their own under playback.
class PlayerDock extends StatelessWidget {
  const PlayerDock({
    super.key,
    required this.portrait,
    required this.timeline,
    required this.playing,
    required this.onPlayPause,
    required this.onBack10,
    required this.onForward10,
    this.onPrevious,
    this.onNext,
    this.showSteps = true,
    required this.audio,
    required this.subtitles,
    this.quality,
    this.openMenu,
    required this.onChip,
    this.chipKeys = const {},
    required this.loop,
    required this.onLoop,
    this.shuffle,
    this.onShuffle,
    this.onUpNext,
  });

  final bool portrait;

  /// The timeline, built by the player so it can follow the position without rebuilding the rest.
  final Widget timeline;
  final bool playing;
  final VoidCallback onPlayPause;
  final VoidCallback onBack10;
  final VoidCallback onForward10;

  /// Null disables the button; [showSteps] false hides both, for a video that isn't part of a show or a queue.
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final bool showSteps;

  final DockChipValue audio;
  final DockChipValue subtitles;

  /// Null when the video has one quality.
  final DockChipValue? quality;
  final DockMenu? openMenu;
  final ValueChanged<DockMenu> onChip;

  /// Where each chip is, so its menu can open above it.
  final Map<DockMenu, GlobalKey> chipKeys;

  /// `off`, `all` or `one`.
  final String loop;
  final VoidCallback onLoop;

  /// Null hides Shuffle, for a PC that can't list what it would pick from.
  final bool? shuffle;
  final VoidCallback? onShuffle;

  /// Null hides Up next.
  final VoidCallback? onUpNext;

  static String loopLabel(String loop) => switch (loop) {
    'all' => 'Loop all',
    'one' => 'Loop one',
    _ => 'Loop off',
  };

  @override
  Widget build(BuildContext context) {
    final transport = Row(
      mainAxisSize: portrait ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: portrait ? MainAxisAlignment.spaceBetween : MainAxisAlignment.center,
      children: _spaced(portrait ? 0 : 10, [
        if (showSteps) DockButton(icon: Icons.skip_previous_rounded, label: 'Previous', onTap: onPrevious),
        DockButton(icon: Icons.replay_10_rounded, label: 'Back 10 seconds', onTap: onBack10),
        Pebble(
          lit: true,
          width: 58,
          height: 58,
          onTap: onPlayPause,
          semanticLabel: playing ? 'Pause' : 'Play',
          child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 32),
        ),
        DockButton(icon: Icons.forward_10_rounded, label: 'Forward 10 seconds', onTap: onForward10),
        if (showSteps) DockButton(icon: Icons.skip_next_rounded, label: 'Next', onTap: onNext),
      ]),
    );
    Widget chip(DockMenu menu, IconData icon, DockChipValue value, String name) => DockChip(
      key: chipKeys[menu],
      icon: icon,
      value: value,
      name: name,
      selected: openMenu == menu,
      dimmed: openMenu != null && openMenu != menu,
      onTap: () => onChip(menu),
    );
    final audioChip = chip(DockMenu.audio, Icons.graphic_eq_rounded, audio, 'Audio');
    final subtitleChip = chip(DockMenu.subtitles, Icons.subtitles_outlined, subtitles, 'Subtitles');
    final qualityChip = quality == null ? null : chip(DockMenu.quality, Icons.hd_outlined, quality!, 'Quality');
    final dim = openMenu != null;
    Widget faded(Widget child) => AnimatedOpacity(opacity: dim ? 0.4 : 1, duration: const Duration(milliseconds: 150), child: child);
    final loopIcon = loop == 'one' ? Icons.repeat_one_rounded : Icons.repeat_rounded;

    final Widget content;
    if (portrait) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          faded(timeline),
          const SizedBox(height: 10),
          faded(transport),
          const SizedBox(height: 16),
          Row(
            children: _spaced(6, [
              // The quality is short and keeps its width; the track names share the rest.
              Flexible(child: audioChip),
              Flexible(child: subtitleChip),
              ?qualityChip,
            ]),
          ),
          const SizedBox(height: 10),
          faded(
            Row(
              children: _spaced(8, [
                if (shuffle != null)
                  Expanded(
                    child: DockButton(icon: Icons.shuffle_rounded, label: 'Shuffle', on: shuffle!, onTap: onShuffle, text: 'Shuffle'),
                  ),
                Expanded(
                  child: DockButton(icon: loopIcon, label: loopLabel(loop), on: loop != 'off', onTap: onLoop, text: loopLabel(loop)),
                ),
                if (onUpNext != null)
                  Expanded(
                    child: DockButton(icon: Icons.queue_play_next_rounded, label: 'Up next', onTap: onUpNext, text: 'Up next'),
                  ),
              ]),
            ),
          ),
        ],
      );
    } else {
      final modes = <Widget>[
        if (shuffle != null) faded(DockButton(icon: Icons.shuffle_rounded, label: shuffle! ? 'Shuffle on' : 'Shuffle off', on: shuffle!, onTap: onShuffle)),
        faded(DockButton(icon: loopIcon, label: loopLabel(loop), on: loop != 'off', onTap: onLoop)),
        if (onUpNext != null) faded(DockButton(icon: Icons.queue_play_next_rounded, label: 'Up next', onTap: onUpNext)),
      ];
      content = LayoutBuilder(
        builder: (context, constraints) {
          // Below this the chips beside playback would be cut down to nothing (the playback buttons take 278 dp, the mode
          // buttons up to 132, and each side gets half of what is left): they get a row of their own, as in portrait.
          if (constraints.maxWidth < landscapeTwoRowWidth) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                faded(timeline),
                const SizedBox(height: 8),
                Center(child: faded(transport)),
                const SizedBox(height: 10),
                Row(
                  children: _spaced(6, [
                    Flexible(child: audioChip),
                    Flexible(child: subtitleChip),
                    ?(qualityChip == null ? null : Flexible(child: qualityChip)),
                    const Spacer(),
                    ...modes,
                  ]),
                ),
              ],
            );
          }
          return _wideLandscape(timeline, transport, audioChip, subtitleChip, qualityChip, modes, faded);
        },
      );
    }
    return DockSlab(padding: portrait ? const EdgeInsets.fromLTRB(16, 16, 16, 16) : const EdgeInsets.fromLTRB(16, 12, 16, 12), child: content);
  }

  /// The landscape dock's width, inside its padding, from which the chips fit beside playback.
  static const landscapeTwoRowWidth = 740.0;

  Widget _wideLandscape(
    Widget timeline,
    Widget transport,
    Widget audioChip,
    Widget subtitleChip,
    Widget? qualityChip,
    List<Widget> modes,
    Widget Function(Widget) faded,
  ) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      faded(timeline),
      const SizedBox(height: 8),
      Row(
        children: [
          // The sides take equal shares, so playback stays in the middle.
          Expanded(child: Row(children: _spaced(6, [Flexible(child: audioChip), Flexible(child: subtitleChip)]))),
          const SizedBox(width: 10),
          faded(transport),
          const SizedBox(width: 10),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: _spaced(6, [?(qualityChip == null ? null : Flexible(child: qualityChip)), ...modes]),
            ),
          ),
        ],
      ),
    ],
  );
}

List<Widget> _spaced(double gap, List<Widget> children) => [
  for (var i = 0; i < children.length; i++) ...[if (i > 0 && gap > 0) SizedBox(width: gap), children[i]],
];

/// The dark slab the dock's controls sit on.
class DockSlab extends StatelessWidget {
  const DockSlab({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.clip = false});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool clip;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    clipBehavior: clip ? Clip.antiAlias : Clip.none,
    decoration: BoxDecoration(
      color: const Color(0xE0111513),
      borderRadius: BorderRadius.circular(26),
      boxShadow: const [BoxShadow(color: Color(0x73000000), blurRadius: 30, offset: Offset(0, 10))],
    ),
    child: child,
  );
}

/// A round pebble in the dock, lit with the accent while its mode is on; with [text], a labelled one.
class DockButton extends StatelessWidget {
  const DockButton({super.key, required this.icon, required this.label, required this.onTap, this.on = false, this.text});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool on;
  final String? text;

  @override
  Widget build(BuildContext context) {
    final iconWidget = Icon(icon, size: text == null ? 22 : 19, color: on ? Palette.accent : null);
    return Tooltip(
      message: label,
      child: Pebble(
        width: text == null ? 40 : null,
        height: 40,
        onTap: onTap,
        enabled: onTap != null,
        semanticLabel: label,
        padding: text == null ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 10),
        child: text == null
            ? iconWidget
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  iconWidget,
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      text!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// A chip sunk into the dock, like the app's input wells, showing what plays now. Narrow, it drops its icon first.
class DockChip extends StatelessWidget {
  const DockChip({super.key, required this.icon, required this.value, required this.name, required this.onTap, this.selected = false, this.dimmed = false});
  final IconData icon;
  final DockChipValue value;

  /// What it changes, for screen readers: "Audio", "Subtitles", "Quality".
  final String name;
  final VoidCallback onTap;

  /// Its menu is open.
  final bool selected;

  /// Another chip's menu is open.
  final bool dimmed;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: dimmed ? 0.45 : 1,
    duration: const Duration(milliseconds: 150),
    child: Semantics(
      button: true,
      selected: selected,
      label: '$name: ${value.label}',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final withIcon = constraints.maxWidth >= 92;
            final label = Text(
              value.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: value.off ? Palette.muted : Palette.ink),
            );
            return Container(
              height: 38,
              padding: EdgeInsets.only(left: withIcon ? 11 : 14, right: 14),
              decoration: ShapeDecoration(
                shape: const StadiumBorder(),
                // Lit from below, so it reads as sunk into the slab.
                gradient: selected
                    ? null
                    : const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFF030504), Color(0xD10A0D0B)],
                        stops: [0, 0.45],
                      ),
                color: selected ? Palette.accentSoft : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (value.busy) ...[
                    const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2, color: Palette.accent)),
                    const SizedBox(width: 8),
                  ] else if (withIcon) ...[
                    Icon(icon, size: 18, color: selected ? Palette.accent : Palette.muted),
                    const SizedBox(width: 7),
                  ],
                  // Given a width, the name gives way to it; otherwise the chip takes the name's.
                  if (constraints.hasBoundedWidth) Flexible(child: label) else label,
                ],
              ),
            );
          },
        ),
      ),
    ),
  );
}

/// The timeline: elapsed time, the bar, and the time left. Dragging shows where it will go and seeks when let go.
class DockTimeline extends StatefulWidget {
  const DockTimeline({
    super.key,
    required this.portrait,
    required this.position,
    required this.duration,
    this.buffered = Duration.zero,
    required this.onSeek,
    this.onDragging,
  });
  final bool portrait;
  final Duration position;
  final Duration duration;
  final Duration buffered;
  final ValueChanged<Duration> onSeek;

  /// True while a finger is on the bar, so the controls stay up.
  final ValueChanged<bool>? onDragging;

  @override
  State<DockTimeline> createState() => _DockTimelineState();
}

class _DockTimelineState extends State<DockTimeline> {
  double? _drag;

  double get _length => widget.duration.inMilliseconds.toDouble();

  double _fraction(double dx, double width) => width <= 0 ? 0 : (dx / width).clamp(0.0, 1.0);

  void _start(double fraction) {
    setState(() => _drag = fraction);
    widget.onDragging?.call(true);
  }

  void _end() {
    final drag = _drag;
    if (drag == null) return;
    setState(() => _drag = null);
    widget.onDragging?.call(false);
    if (_length > 0) widget.onSeek(Duration(milliseconds: (drag * _length).round()));
  }

  @override
  Widget build(BuildContext context) {
    final length = _length;
    final shown = _drag ?? (length > 0 ? (widget.position.inMilliseconds / length).clamp(0.0, 1.0) : 0.0);
    final buffered = length > 0 ? (widget.buffered.inMilliseconds / length).clamp(0.0, 1.0) : 0.0;
    final at = Duration(milliseconds: (shown * length).round());
    final elapsed = formatClock(at.inMilliseconds);
    final left = '−${formatClock((widget.duration - at).inMilliseconds)}';
    const timeStyle = TextStyle(fontSize: 12.5, color: Color(0xD9FFFFFF), fontFeatures: [FontFeature.tabularFigures()]);
    final bar = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Semantics(
          slider: true,
          label: 'Position',
          value: elapsed,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: length > 0 ? (d) => _start(_fraction(d.localPosition.dx, width)) : null,
            onHorizontalDragUpdate: length > 0 ? (d) => setState(() => _drag = _fraction(d.localPosition.dx, width)) : null,
            onHorizontalDragEnd: (_) => _end(),
            onHorizontalDragCancel: _end,
            // A tap seeks where it lands. A hold that becomes a drag is the drag's: it seeks once, where it lets go.
            onTapUp: length > 0
                ? (d) {
                    _start(_fraction(d.localPosition.dx, width));
                    _end();
                  }
                : null,
            child: SizedBox(
              height: 28,
              child: CustomPaint(painter: _TimelinePainter(shown, buffered, dragging: _drag != null)),
            ),
          ),
        );
      },
    );
    if (widget.portrait) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          bar,
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(elapsed, style: timeStyle),
              Text(left, style: timeStyle),
            ],
          ),
        ],
      );
    }
    return Row(
      children: [
        Text(elapsed, style: timeStyle),
        const SizedBox(width: 12),
        Expanded(child: bar),
        const SizedBox(width: 12),
        Text(left, style: timeStyle),
      ],
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter(this.position, this.buffered, {required this.dragging});
  final double position;
  final double buffered;
  final bool dragging;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final height = dragging ? 6.0 : 4.0;
    RRect bar(double to) => RRect.fromLTRBR(0, y - height / 2, size.width * to, y + height / 2, Radius.circular(height / 2));
    canvas.drawRRect(bar(1), Paint()..color = const Color(0x33FFFFFF));
    if (buffered > 0) canvas.drawRRect(bar(buffered), Paint()..color = const Color(0x40FFFFFF));
    if (position > 0) canvas.drawRRect(bar(position), Paint()..color = Palette.accent);
    final knob = Offset(size.width * position, y);
    final radius = dragging ? 10.0 : 7.0;
    canvas.drawCircle(
      knob + const Offset(0, 1),
      radius,
      Paint()
        ..color = const Color(0x80000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    canvas.drawCircle(knob, radius, Paint()..color = Palette.knob);
  }

  @override
  bool shouldRepaint(_TimelinePainter old) => old.position != position || old.buffered != buffered || old.dragging != dragging;
}

/// The next episode in place of the dock's buttons, as on the PC: the glowing top edge counts down, and it plays when
/// that runs out unless canceled.
class UpNextDock extends StatelessWidget {
  const UpNextDock({
    super.key,
    required this.title,
    this.detail,
    required this.secondsLeft,
    required this.progress,
    required this.timeline,
    required this.onPlay,
    required this.onCancel,
    required this.portrait,
  });
  final String title;
  final String? detail;
  final int secondsLeft;

  /// How much of the countdown has run, 0 to 1.
  final double progress;
  final Widget timeline;
  final VoidCallback onPlay;
  final VoidCallback onCancel;
  final bool portrait;

  @override
  Widget build(BuildContext context) {
    final words = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Up next · playing in $secondsLeft s', style: const TextStyle(color: Palette.muted, fontSize: 12)),
        const SizedBox(height: 2),
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Palette.ink, fontSize: 16, fontWeight: FontWeight.w600),
        ),
        if (detail != null)
          Text(
            detail!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Palette.muted, fontSize: 12.5),
          ),
      ],
    );
    final cancel = TextButton(
      onPressed: onCancel,
      style: TextButton.styleFrom(
        foregroundColor: Palette.ink,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      child: const Text('Cancel'),
    );
    final play = Pebble(
      lit: true,
      height: 40,
      onTap: onPlay,
      semanticLabel: 'Play now',
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.play_arrow_rounded, size: 20),
          SizedBox(width: 4),
          Text('Play now', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        ],
      ),
    );
    return DockSlab(
      clip: true,
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The lit edge fills toward the next episode, like the glow along the PC's posters.
          Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: progress.clamp(0.0, 1.0),
              child: Container(
                height: 3,
                decoration: const BoxDecoration(
                  color: Palette.accent,
                  boxShadow: [BoxShadow(color: Color(0xB39FD4A8), blurRadius: 10, spreadRadius: 1)],
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(16, portrait ? 14 : 10, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (portrait) ...[
                  words,
                  const SizedBox(height: 12),
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [cancel, const SizedBox(width: 6), play]),
                ] else
                  Row(
                    children: [
                      Expanded(child: words),
                      cancel,
                      const SizedBox(width: 6),
                      play,
                    ],
                  ),
                const SizedBox(height: 8),
                timeline,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A chip's short menu: what it can change to, with the one playing ticked, and the full options below.
class ChipMenuCard extends StatelessWidget {
  const ChipMenuCard({super.key, required this.title, required this.options, required this.onAllOptions, this.maxHeight = 320});
  final String title;
  final List<ChipMenuOption> options;
  final VoidCallback onAllOptions;
  final double maxHeight;

  @override
  Widget build(BuildContext context) => Material(
    color: Palette.surface,
    borderRadius: BorderRadius.circular(20),
    clipBehavior: Clip.antiAlias,
    elevation: 0,
    child: DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [BoxShadow(color: Color(0x8C000000), blurRadius: 30, offset: Offset(0, 10))],
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
                child: Text(title, style: const TextStyle(color: Palette.muted, fontSize: 12.5)),
              ),
              for (final option in options) _ChipMenuRow(option: option),
              if (options.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(14, 6, 14, 10),
                  child: Text('Nothing to choose yet.', style: TextStyle(color: Palette.muted, fontSize: 13.5)),
                ),
              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: onAllOptions,
                child: const SizedBox(
                  height: 44,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      children: [
                        Icon(Icons.tune_rounded, size: 18, color: Palette.muted),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text('All options', style: TextStyle(color: Palette.muted, fontSize: 14)),
                        ),
                        Icon(Icons.chevron_right_rounded, size: 20, color: Palette.muted),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class ChipMenuOption {
  const ChipMenuOption({required this.name, this.detail, required this.selected, this.busy = false, required this.onTap});
  final String name;
  final String? detail;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;
}

class _ChipMenuRow extends StatelessWidget {
  const _ChipMenuRow({required this.option});
  final ChipMenuOption option;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: option.selected,
    button: true,
    child: Material(
      color: option.selected ? Palette.accentSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: option.onTap,
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      text: option.name,
                      style: TextStyle(fontSize: 14.5, color: Palette.ink, fontWeight: option.selected ? FontWeight.w600 : FontWeight.w500),
                      children: [
                        if (option.detail != null)
                          TextSpan(
                            text: '  ${option.detail}',
                            style: const TextStyle(fontSize: 12.5, color: Palette.muted, fontWeight: FontWeight.w400),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                if (option.busy)
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Palette.accent))
                else if (option.selected)
                  const Icon(Icons.check_rounded, size: 20, color: Palette.accent),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
