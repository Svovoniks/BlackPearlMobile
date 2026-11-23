import 'package:blackpearl_mobile/ui/pebbles.dart';
import 'package:blackpearl_mobile/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('a pebble disabled under the finger lets go of the press, and is drawn unpressed once enabled', (tester) async {
    final enabled = ValueNotifier(true);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: Center(
            child: ValueListenableBuilder<bool>(
              valueListenable: enabled,
              builder: (context, on, _) => Pebble(width: 80, height: 50, enabled: on, onTap: () {}, child: const Text('Play')),
            ),
          ),
        ),
      ),
    );
    double scale() => tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;
    final gesture = await tester.startGesture(tester.getCenter(find.text('Play')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(scale(), lessThan(1), reason: 'pressed');
    enabled.value = false;
    await tester.pump();
    await gesture.up();
    enabled.value = true;
    await tester.pump();
    expect(scale(), 1);
  });
}
