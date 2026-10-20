import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../widgets/glass_card.dart';

/// 「方案计算」页：根据推免方案计算 811 / 82 结果。
/// 本版交付：警示/提示横条 + 方案单选；计算主体功能后续迭代。
class SchemePage extends StatefulWidget {
  const SchemePage({super.key});

  @override
  State<SchemePage> createState() => _SchemePageState();
}

class _SchemePageState extends State<SchemePage> {
  static const String _infoText =
      '提示：本年度免试推荐适用的学业综合成绩计算范围包括思想政治理论课（含思政选修课）、'
      '公共外语/大学外语（含拓展类课程）、平台课/公共计算机、部类共同、部类基础（必修）、'
      '部类核心课、专业基础公共数学、人工智能与数据技术平台课/数据与信息技术课、'
      '学科基础、专业核心课、专业必修以及所在院系开设的学年论文。'
      '对于转专业及退出拔尖创新人才培养项目的学生，'
      '转入专业培养方案不要求的课程，不计入免试推荐绩点。';

  /// 当前选中的方案（'811' / '82'）；null 表示尚未选择
  String? _scheme;

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
              const SizedBox(height: 20),
              _buildWarningBanner(colorScheme),
              const SizedBox(height: 12),
              _buildInfoBanner(colorScheme),
              const SizedBox(height: 16),
              _buildSchemeChooser(colorScheme),
            ],
          ),
        ),
      ),
    );
  }

  /// 红色警示：结果仅作参考，需自行核对培养方案与院系方案
  Widget _buildWarningBanner(ColorScheme cs) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 11),
      decoration: BoxDecoration(
        color: AppTheme.error.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.error.withValues(alpha: .35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: AppTheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '计算结果仅作为参考，请务必自行核对培养方案与院系方案的要求后再使用。',
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: AppTheme.error.withValues(alpha: .92),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 蓝色提示：免试推荐适用的学业综合成绩计算范围
  Widget _buildInfoBanner(ColorScheme cs) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 11),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.primary.withValues(alpha: .3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: cs.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _infoText,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.55,
                color: cs.onSurface.withValues(alpha: .8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 方案单选卡：811 方案 / 82 方案（互斥单选，默认未选中）
  Widget _buildSchemeChooser(ColorScheme cs) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: RadioGroup<String>(
        groupValue: _scheme,
        onChanged: (v) {
          if (v != null && v != _scheme) {
            setState(() => _scheme = v);
          }
        },
        child: Column(
          children: [
            _schemeRow(cs, value: '811', label: '811 方案'),
            _schemeRow(cs, value: '82', label: '82 方案'),
          ],
        ),
      ),
    );
  }

  Widget _schemeRow(ColorScheme cs, {required String value, required String label}) {
    final selected = _scheme == value;
    return InkWell(
      onTap: () => setState(() => _scheme = value),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Radio<String>(
              value: value,
              activeColor: cs.primary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: cs.onSurface.withValues(alpha: selected ? .95 : .8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
