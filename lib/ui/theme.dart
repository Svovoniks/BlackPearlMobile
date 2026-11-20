import 'package:material_ui/material_ui.dart';

/// The Pebble palette from the desktop app, on its dark canvas.
class Palette {
  Palette._();
  static const canvas = Color(0xFF0F1311);
  static const surface = Color(0xFF151A17);
  static const elevated = Color(0xFF1E2420);
  static const well = Color(0xFF0A0D0B);
  static const ink = Color(0xFFEAF0EB);
  static const muted = Color(0xFF9BA89F);
  static const accent = Color(0xFF9FD4A8);
  static const accentInk = Color(0xFF0E2A15);
  static const accentSoft = Color(0xFF1F3324);
  static const danger = Color(0xFFF07A6E);
  static const cyan = Color(0xFF6CC3D9);
  static const knob = Color(0xFFF4F7F4);
}

const String displayFont = 'SourceSerif4';

/// Serif display text, as the desktop app's titles.
TextStyle display(double size, {Color color = Palette.ink, FontWeight weight = FontWeight.w600}) => TextStyle(
  fontFamily: displayFont,
  fontSize: size,
  fontWeight: weight,
  color: color,
  height: 1.15,
  letterSpacing: -0.2,
  fontVariations: [FontVariation('wght', weight.value.toDouble()), FontVariation('opsz', size.clamp(8, 60).toDouble())],
);

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: Palette.canvas,
    colorScheme: const ColorScheme.dark(
      surface: Palette.surface,
      primary: Palette.accent,
      onPrimary: Palette.accentInk,
      secondary: Palette.accent,
      onSurface: Palette.ink,
      error: Palette.danger,
    ),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: Palette.ink, displayColor: Palette.ink),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Palette.elevated,
      contentTextStyle: TextStyle(color: Palette.ink, fontSize: 14),
      behavior: SnackBarBehavior.floating,
      shape: StadiumBorder(),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Palette.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      showDragHandle: false,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: Palette.accent,
      selectionColor: Palette.accentSoft,
      selectionHandleColor: Palette.accent,
    ),
  );
}
