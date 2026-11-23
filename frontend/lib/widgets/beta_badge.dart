import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// 「Beta」标签：标记仍在打磨、口径可能调整的功能。
///
/// 取主色的低透明度底色 + 主色文字，跟应用整体同色系，不另起一套配色；
/// 这样在浅色/深色以及不同主题预设下都能自然跟随。
class BetaBadge extends StatelessWidget {
  const BetaBadge({super.key, this.fontSize = 11, this.padding});

  final double fontSize;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding:
          padding ??
          EdgeInsets.symmetric(horizontal: fontSize * 0.5, vertical: 1.5),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(fontSize * 0.45),
      ),
      child: Text(
        'BETA',
        style: TextStyle(
          fontFamily: AppTheme.sansFontFamily,
          fontSize: fontSize,
          height: 1.25,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
          color: cs.primary,
        ),
      ),
    );
  }
}
