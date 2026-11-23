import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// 「Beta」黄标签：标记仍在打磨、口径可能调整的功能。
///
/// 用琥珀色底 + 深色字，而不是把字直接染黄——浅色主题下黄字对比度不足。
class BetaBadge extends StatelessWidget {
  const BetaBadge({super.key, this.fontSize = 11, this.padding});

  final double fontSize;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
          padding ??
          EdgeInsets.symmetric(horizontal: fontSize * 0.5, vertical: 1.5),
      decoration: BoxDecoration(
        color: AppTheme.warning,
        borderRadius: BorderRadius.circular(fontSize * 0.45),
      ),
      child: Text(
        'Beta',
        style: TextStyle(
          fontFamily: AppTheme.sansFontFamily,
          fontSize: fontSize,
          height: 1.25,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
          color: const Color(0xFF3D2A00),
        ),
      ),
    );
  }
}
