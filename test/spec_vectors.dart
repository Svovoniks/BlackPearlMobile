import 'dart:io';

/// One row of the "Test vectors" table in PHONE-REMOTE.md.
class SpecVector {
  const SpecVector(this.keyHex, this.text, this.auth);
  final String keyHex;

  /// The signed text, with ⏎ turned into line feeds.
  final String text;
  final String auth;

  List<String> get parts => text.split('\n');
}

/// Reads the test vectors from the protocol file itself, so the tests check the contract as written.
List<SpecVector> readSpecVectors() {
  final lines = File('PHONE-REMOTE.md').readAsLinesSync();
  final start = lines.indexWhere((l) => l.trim() == 'Test vectors:');
  if (start < 0) throw StateError('PHONE-REMOTE.md has no "Test vectors:" table');
  final cell = RegExp(r'`([^`]*)`');
  final vectors = <SpecVector>[];
  for (final line in lines.skip(start + 1)) {
    if (!line.startsWith('|')) {
      if (vectors.isNotEmpty) break;
      continue;
    }
    final cells = cell.allMatches(line).map((m) => m.group(1)!).toList();
    if (cells.length != 3) continue;
    vectors.add(SpecVector(cells[0], cells[1].replaceAll('⏎', '\n'), cells[2]));
  }
  return vectors;
}

/// Lower-case hex of [bytes].
String hexOf(Iterable<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
