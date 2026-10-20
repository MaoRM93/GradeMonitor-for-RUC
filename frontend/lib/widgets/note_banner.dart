import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// 红色警示 / 蓝色提示横条（两页统一规范）：
/// 图标、标题、正文**各自换行**，标题加粗。
/// - 红条：三角感叹号（warning_amber_rounded）
/// - 蓝条：info_outline_rounded
class NoteBanner extends StatelessWidget {
  const NoteBanner.warning({super.key, required this.title, required this.text})
      : warning = true;

  const NoteBanner.info({super.key, required this.title, required this.text})
      : warning = false;

  final String title;
  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mainColor = warning ? AppTheme.error : cs.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
      decoration: BoxDecoration(
        color: mainColor.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: mainColor.withValues(alpha: warning ? .35 : .3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            warning ? Icons.warning_amber_rounded : Icons.info_outline_rounded,
            size: 18,
            color: mainColor,
          ),
          const SizedBox(height: 7),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: warning
                  ? AppTheme.error.withValues(alpha: .95)
                  : cs.primary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: warning ? 13 : 12.5,
              height: warning ? 1.5 : 1.55,
              color: warning
                  ? AppTheme.error.withValues(alpha: .92)
                  : cs.onSurface.withValues(alpha: .8),
            ),
          ),
        ],
      ),
    );
  }
}
