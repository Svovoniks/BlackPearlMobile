import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads the fonts the app draws with (Roboto, the Material icons, and the titles' Source Serif 4), for tests about
/// what fits where: the test font draws every letter 1 em wide, about twice as wide as real text.
Future<void> loadRealFonts() async {
  var dir = File(Platform.resolvedExecutable).parent;
  while (!Directory('${dir.path}/material_fonts').existsSync() && dir.parent.path != dir.path) {
    dir = dir.parent;
  }
  // Names differ in case between platforms' SDK downloads (Roboto-Regular.ttf, roboto-regular.ttf).
  final fonts = Directory('${dir.path}/material_fonts').listSync().whereType<File>().toList();
  Future<ByteData> font(String name) async {
    final file = fonts.firstWhere(
      (f) => f.uri.pathSegments.last.toLowerCase() == name,
      orElse: () => throw StateError('No $name among ${fonts.map((f) => f.uri.pathSegments.last).join(', ')}'),
    );
    return ByteData.sublistView(await file.readAsBytes());
  }

  await (FontLoader('Roboto')
        ..addFont(font('roboto-regular.ttf'))
        ..addFont(font('roboto-medium.ttf')))
      .load();
  await (FontLoader('MaterialIcons')..addFont(font('materialicons-regular.otf'))).load();
  await (FontLoader('SourceSerif4')..addFont(Future.value(ByteData.sublistView(await File('assets/fonts/SourceSerif4.ttf').readAsBytes())))).load();
}
