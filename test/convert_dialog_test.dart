import 'package:blackpearl_mobile/ui/app_prompts.dart';
import 'package:blackpearl_mobile/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Future<(Future<bool>, ValueNotifier<int>)> open(WidgetTester tester) async {
    final offer = ValueNotifier(0);
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: Builder(builder: (c) => SizedBox.expand(child: Builder(builder: (c2) {
      context = c2;
      return const SizedBox();
    })))));
    final answer = confirmConvertAnyway(context, '480p', offer: offer);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Convert anyway?'), findsOneWidget);
    return (answer, offer);
  }

  testWidgets('Convert anyway answers yes, Play as it is no', (tester) async {
    var (answer, _) = await open(tester);
    await tester.tap(find.text('Convert anyway'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(await answer, isTrue);
    (answer, _) = await open(tester);
    await tester.tap(find.text('Play as it is'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(await answer, isFalse);
  });

  testWidgets('another stream ending the offer closes the dialog, answering no', (tester) async {
    final (answer, offer) = await open(tester);
    offer.value = 1;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Convert anyway?'), findsNothing);
    expect(await answer, isFalse);
    // Changing again after it closed does nothing more.
    offer.value = 2;
    await tester.pump();
  });
}
