import 'package:flutter/material.dart';
import '../core/theme/app_theme.dart';

/// 毛玻璃风格卡片 - LocalSend 风格核心组件
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double borderRadius;
  final VoidCallback? onTap;
  final Color? backgroundColor;
  final double? width;
  final double? height;
  final BoxBorder? border;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.margin,
    this.borderRadius = 16,
    this.onTap,
    this.backgroundColor,
    this.width,
    this.height,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final card = Container(
      width: width,
      height: height,
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: backgroundColor ?? theme.cardTheme.color,
        borderRadius: BorderRadius.circular(borderRadius),
        // 卡片靠底色 + 阴影与背景区分，不再画描边分割线；
        // 需要描边时由调用方显式传 border。
        border: border,
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withValues(alpha: .3)
                : const Color(0xFF1E293B).withValues(alpha: .04),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: isDark
                ? Colors.black.withValues(alpha: .15)
                : const Color(0xFF1E293B).withValues(alpha: .02),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: child,
    );

    if (onTap != null) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(borderRadius),
        child: card,
      );
    }

    return card;
  }
}

/// 带脉动点的状态指示器
class PulsingStatusDot extends StatefulWidget {
  final bool active;
  final double size;

  const PulsingStatusDot({super.key, required this.active, this.size = 10});

  @override
  State<PulsingStatusDot> createState() => _PulsingStatusDotState();
}

class _PulsingStatusDotState extends State<PulsingStatusDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _animation = Tween<double>(
      begin: .6,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    if (widget.active) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(PulsingStatusDot old) {
    super.didUpdateWidget(old);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.active
                ? AppTheme.success.withValues(alpha: _animation.value)
                : Colors.grey.withValues(alpha: .4),
            boxShadow: widget.active
                ? [
                    BoxShadow(
                      color: AppTheme.success.withValues(alpha: .3),
                      blurRadius: 8 * _animation.value,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
        );
      },
    );
  }
}

/// GPA / 成绩 Badge 组件
class GpaBadge extends StatelessWidget {
  final String value;
  final double size;

  const GpaBadge({super.key, required this.value, this.size = 14});

  @override
  Widget build(BuildContext context) {
    final gpa = double.tryParse(value) ?? 0;
    final bgColor = gpa >= 3.7
        ? AppTheme.success.withValues(alpha: .15)
        : gpa >= 3.0
        ? AppTheme.warning.withValues(alpha: .15)
        : AppTheme.error.withValues(alpha: .15);
    final textColor = gpa >= 3.7
        ? AppTheme.success
        : gpa >= 3.0
        ? AppTheme.warning
        : AppTheme.error;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        value,
        style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.w700,
          color: textColor,
        ),
      ),
    );
  }
}
