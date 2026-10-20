import 'package:flutter/material.dart';

/// 「方案计算」页：根据推免方案计算 811 / 82 结果
/// 本页为骨架版本，标题与小标题先就位，主体功能后续迭代。
class SchemePage extends StatelessWidget {
  const SchemePage({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 44, 28, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '方案计算',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '根据您的推免方案计算您的 811 / 82 结果',
                style: TextStyle(
                  fontSize: 14,
                  color: colorScheme.onSurface.withValues(alpha: .5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
