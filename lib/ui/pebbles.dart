import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// A raised "pebble": the surface every button sits on. Soft top highlight, drop shadow, no outline.
class Pebble extends StatefulWidget {
  const Pebble({
    super.key,
    required this.child,
    this.onTap,
    this.lit = false,
    this.width,
    this.height = 44,
    this.radius,
    this.padding = EdgeInsets.zero,
    this.semanticLabel,
    this.enabled = true,
    this.color,
    this.tapArea,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// The least room that takes the touch, around a pebble drawn smaller than a fingertip: the pebble keeps its look,
  /// centered in it. Null: the pebble itself.
  final Size? tapArea;

  /// A fingertip: Android's 48 dp.
  static const fingertip = Size(48, 48);

  /// The accent pebble, for the main action.
  final bool lit;
  final double? width;
  final double height;

  /// Corner radius; a stadium when null.
  final double? radius;
  final EdgeInsetsGeometry padding;
  final String? semanticLabel;
  final bool enabled;
  final Color? color;

  @override
  State<Pebble> createState() => _PebbleState();
}

class _PebbleState extends State<Pebble> {
  bool _pressed = false;

  bool get _active => widget.enabled && widget.onTap != null;

  // A pebble disabled under the finger hears no end to the press (its tap handlers are gone), and showed it pressed
  // again once enabled.
  @override
  void didUpdateWidget(Pebble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_active) _pressed = false;
  }

  // Its tap handlers being removed also cancels the press, while the pebble builds: nothing to set again then.
  void _press(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(widget.radius ?? widget.height / 2);
    final base = widget.color ?? (widget.lit ? Palette.accent : Palette.elevated);
    final highlight = Color.lerp(base, Colors.white, widget.lit ? 0.22 : 0.05)!;
    final foreground = widget.lit ? Palette.accentInk : Palette.ink;
    final pressed = _pressed && _active;
    final decoration = BoxDecoration(
      borderRadius: radius,
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: pressed ? [base, base] : [highlight, base],
        stops: const [0, 0.42],
      ),
      boxShadow: pressed
          ? const [BoxShadow(color: Color(0x66000000), blurRadius: 3, offset: Offset(0, 1))]
          : widget.lit
          ? [BoxShadow(color: Palette.accent.withValues(alpha: 0.28), blurRadius: 14, offset: const Offset(0, 4))]
          : const [BoxShadow(color: Color(0x73000000), blurRadius: 8, offset: Offset(0, 3))],
    );
    Widget content = AnimatedContainer(
      duration: const Duration(milliseconds: 90),
      width: widget.width,
      height: widget.height,
      padding: widget.padding,
      decoration: decoration,
      // Without a fixed width the pebble hugs its content instead of filling the space it's offered.
      child: Center(
        widthFactor: widget.width == null ? 1 : null,
        child: IconTheme.merge(
          data: IconThemeData(color: foreground, size: 22),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: foreground, fontWeight: FontWeight.w600, fontSize: 14),
            child: widget.child,
          ),
        ),
      ),
    );
    content = AnimatedScale(scale: pressed ? 0.95 : 1, duration: const Duration(milliseconds: 90), child: content);
    content = AnimatedOpacity(opacity: widget.enabled ? 1 : 0.38, duration: const Duration(milliseconds: 150), child: content);
    final tapArea = widget.tapArea;
    if (tapArea != null) {
      // Padding rather than a centering box, so a pebble that fills the width it is given still does.
      final above = math.max(0.0, (tapArea.height - widget.height) / 2);
      final width = widget.width;
      final beside = width == null ? 0.0 : math.max(0.0, (tapArea.width - width) / 2);
      content = Padding(padding: EdgeInsets.symmetric(vertical: above, horizontal: beside), child: content);
      if (width == null && tapArea.width > 0) content = ConstrainedBox(constraints: BoxConstraints(minWidth: tapArea.width), child: content);
    }
    return Semantics(
      button: true,
      enabled: _active,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _active ? (_) => _press(true) : null,
        onTapCancel: _active ? () => _press(false) : null,
        onTapUp: _active ? (_) => _press(false) : null,
        onTap: _active
            ? () {
                HapticFeedback.selectionClick();
                widget.onTap!();
              }
            : null,
        child: content,
      ),
    );
  }
}

/// A sunk "well": tracks and inputs sit in one.
class Well extends StatelessWidget {
  const Well({super.key, this.child, this.height, this.width, this.radius, this.padding = EdgeInsets.zero});
  final Widget? child;
  final double? height;
  final double? width;
  final double? radius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius ?? (height ?? 40) / 2);
    return Container(
      height: height,
      width: width,
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: r,
        // The inner shadow at the top and the faint light at the bottom edge make it read as pressed in.
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF030403), Palette.well, Palette.well, Color(0xFF111512)],
          stops: [0, 0.35, 0.9, 1],
        ),
      ),
      child: child,
    );
  }
}

/// A flat "slab": a quiet surface for grouped content.
class Slab extends StatelessWidget {
  const Slab({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.radius = 20, this.color = Palette.surface});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color.lerp(color, Colors.white, 0.03)!, color],
        stops: const [0, 0.2],
      ),
      boxShadow: const [BoxShadow(color: Color(0x59000000), blurRadius: 6, offset: Offset(0, 2))],
    ),
    child: child,
  );
}

/// A text button styled as a wide pebble, for actions in panels and sheets.
class PebbleButton extends StatelessWidget {
  const PebbleButton({
    super.key,
    required this.label,
    this.onTap,
    this.lit = false,
    this.icon,
    this.height = 48,
    this.color,
    this.textColor,
  });
  final String label;
  final VoidCallback? onTap;
  final bool lit;
  final IconData? icon;
  final double height;
  final Color? color;
  final Color? textColor;

  @override
  Widget build(BuildContext context) => Pebble(
    // A disabled main action reads as unavailable, not as a faded accent.
    lit: lit && onTap != null,
    height: height,
    onTap: onTap,
    enabled: onTap != null,
    color: color,
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 18, color: textColor), const SizedBox(width: 8)],
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: textColor),
          ),
        ),
      ],
    ),
  );
}
