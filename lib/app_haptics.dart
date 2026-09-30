import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

abstract final class AppHaptics {
  static bool enabled = true;
  static int _lastAt = 0;

  static void light({bool force = false}) {
    if (!enabled) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastAt < 40) return;
    _lastAt = now;
    HapticFeedback.lightImpact();
  }
}

class AppHapticSplashFactory extends InteractiveInkFeatureFactory {
  const AppHapticSplashFactory();

  @override
  InteractiveInkFeature create({
    required MaterialInkController controller,
    required RenderBox referenceBox,
    required Offset position,
    required Color color,
    required TextDirection textDirection,
    bool containedInkWell = false,
    RectCallback? rectCallback,
    BorderRadius? borderRadius,
    ShapeBorder? customBorder,
    double? radius,
    VoidCallback? onRemoved,
  }) {
    AppHaptics.light();
    return InkRipple.splashFactory.create(
      controller: controller,
      referenceBox: referenceBox,
      position: position,
      color: color,
      textDirection: textDirection,
      containedInkWell: containedInkWell,
      rectCallback: rectCallback,
      borderRadius: borderRadius,
      customBorder: customBorder,
      radius: radius,
      onRemoved: onRemoved,
    );
  }
}
