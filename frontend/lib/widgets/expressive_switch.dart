import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// Material 3 Expressive 风格开关。
///
/// 本组件不持有固定像素尺寸：调用方只提供一个相对高度，轨道、描边、滑块、
/// 勾号和位移均从该高度按比例推导。
class ExpressiveSwitch extends StatefulWidget {
  const ExpressiveSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    required this.height,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final double height;

  @override
  State<ExpressiveSwitch> createState() => _ExpressiveSwitchState();
}

class _ExpressiveSwitchState extends State<ExpressiveSwitch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
      value: widget.value ? 1 : 0,
    );
  }

  @override
  void didUpdateWidget(covariant ExpressiveSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _controller.animateTo(
        widget.value ? 1 : 0,
        curve: const Cubic(.175, .885, .32, 1.275),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // The inactive track needs enough tonal separation to remain legible on
    // every preset, particularly the near-black surfaces in dark mode.
    final inactiveTrack = Color.alphaBlend(
      scheme.onSurface.withValues(alpha: isDark ? .16 : .075),
      scheme.surfaceContainerHighest,
    );
    final inactiveOutline = Color.alphaBlend(
      scheme.onSurface.withValues(alpha: isDark ? .62 : .46),
      inactiveTrack,
    );
    final inactiveThumb = Color.alphaBlend(
      scheme.onSurface.withValues(alpha: isDark ? .72 : .56),
      inactiveTrack,
    );
    return Semantics(
      toggled: widget.value,
      enabled: widget.onChanged != null,
      child: GestureDetector(
        onTap: widget.onChanged == null
            ? null
            : () => widget.onChanged!(!widget.value),
        child: SizedBox(
          height: widget.height,
          child: AspectRatio(
            aspectRatio: 1.625,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final h = constraints.maxHeight;
                final w = constraints.maxWidth;
                return AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) {
                    final t = _controller.value;
                    final thumb = lerpDouble(h * .52, h * .78, t)!;
                    final inset = (h - thumb) / 2;
                    final left = lerpDouble(inset, w - inset - thumb, t)!;
                    return DecoratedBox(
                      decoration: BoxDecoration(
                        color: Color.lerp(inactiveTrack, scheme.primary, t),
                        borderRadius: BorderRadius.circular(h),
                        border: t < .5
                            ? Border.all(color: inactiveOutline, width: h * .06)
                            : null,
                      ),
                      child: Stack(
                        children: [
                          Positioned(
                            left: left,
                            top: inset,
                            width: thumb,
                            height: thumb,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Color.lerp(
                                  inactiveThumb,
                                  scheme.onPrimary,
                                  t,
                                ),
                                shape: BoxShape.circle,
                              ),
                              child: Opacity(
                                opacity: Curves.easeIn.transform(t),
                                child: CustomPaint(
                                  painter: _CheckPainter(
                                    color: scheme.primary,
                                    stroke: thumb * .105,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _CheckPainter extends CustomPainter {
  const _CheckPainter({required this.color, required this.stroke});

  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = stroke
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(size.width * .24, size.height * .52)
      ..lineTo(size.width * .43, size.height * .70)
      ..lineTo(size.width * .76, size.height * .33);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CheckPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.stroke != stroke;
}
