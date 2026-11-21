import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:blackpearl_mobile/ui/player_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

DisplayFeature cutout(Rect bounds) => DisplayFeature(bounds: bounds, type: DisplayFeatureType.cutout, state: DisplayFeatureState.unknown);

void main() {
  test('with the bars hidden, a punch-hole camera at the top still keeps the controls below it', () {
    final insets = controlInsets(MediaQueryData(size: const Size(411, 914), displayFeatures: [cutout(const Rect.fromLTWH(190, 8, 30, 30))]));
    expect(insets.top, 38);
    expect(insets.left, 0);
  });

  test('turned sideways, the cutout is on the left', () {
    final insets = controlInsets(MediaQueryData(size: const Size(914, 411), displayFeatures: [cutout(const Rect.fromLTWH(8, 190, 30, 30))]));
    expect(insets.left, 38);
    expect(insets.top, 0);
  });

  test("the cutout Android reports counts when Flutter reports none", () {
    final insets = controlInsets(const MediaQueryData(size: Size(411, 914)), cutout: const EdgeInsets.only(top: 34));
    expect(insets.top, 34);
  });

  test('the gesture strip and the bars count when they are larger', () {
    final insets = controlInsets(const MediaQueryData(
      size: Size(411, 914),
      viewPadding: EdgeInsets.only(top: 52),
      systemGestureInsets: EdgeInsets.only(bottom: 32),
    ));
    expect(insets, const EdgeInsets.only(top: 52, bottom: 32));
  });
}
