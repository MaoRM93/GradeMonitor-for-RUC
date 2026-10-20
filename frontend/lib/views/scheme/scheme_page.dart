import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../providers/grades_provider.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/note_banner.dart';
import 'scheme_core.dart';

/// 「方案计算」页：根据推免方案计算 811 / 82 结果。
///
/// 计算规则（用户给定，勿改）：
/// - 811 方案 = 核心绩×80% + 学术科研能力×10% + 综合能力×10%
/// - 82 方案  = 核心绩×80% + 学术科研能力×20%
/// - 核心绩由 App 自动计算（白名单学分加权，见 scheme_core.dart），
///   默认只读；双击可自定义，自定义后可一键恢复自动值
/// - 学术科研能力 / 综合能力为文本框输入，上限各 4.0
class SchemePage extends ConsumerStatefulWidget {
  const SchemePage({super.key});

  @override
  ConsumerState<SchemePage> createState() => _SchemePageState();
}

class _SchemePageState extends ConsumerState<SchemePage> {
  static const String _infoText =
      '提示：本年度免试推荐适用的学业综合成绩计算范围包括思想政治理论课（含思政选修课）、'
      '公共外语/大学外语（含拓展类课程）、平台课/公共计算机、部类共同、部类基础（必修）、'
      '部类核心课、专业基础公共数学、人工智能与数据技术平台课/数据与信息技术课、'
      '学科基础、专业核心课、专业必修以及所在院系开设的学年论文。'
      '对于转专业及退出拔尖创新人才培养项目的学生，'
      '转入专业培养方案不要求的课程，不计入免试推荐绩点。';

  /// 当前选中的方案（'811' / '82'）；null 表示尚未选择
  String? _scheme;

  final _coreCtrl = TextEditingController();
  final _academicCtrl = TextEditingController();
  final _comprehensiveCtrl = TextEditingController();

  /// 用户已双击自定义核心绩（此后不再被自动值覆盖）
  bool _coreCustom = false;

  /// 当前是否处于核心绩可编辑状态（双击进入）
  bool _coreEditing = false;

  /// 计算结果精度开关：true = 5 位小数（不足补 0），false = 保留 2 位
  bool _precise5 = false;

  @override
  void initState() {
    super.initState();
    // 首次加载：从已缓存的成绩数据同步核心绩自动值
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncCore());
  }

  @override
  void dispose() {
    _coreCtrl.dispose();
    _academicCtrl.dispose();
    _comprehensiveCtrl.dispose();
    super.dispose();
  }

  /// 与成绩数据同步核心绩自动值（仅自动模式下写入）
  void _syncCore() {
    if (_coreCustom || _coreEditing) return;
    final grades = ref.read(gradesProvider).asData?.value;
    final gpa = grades == null ? null : CoreGpaUtil.analyze(grades).gpa;
    final text = gpa == null ? '' : _formatGpa(gpa);
    if (_coreCtrl.text != text) _coreCtrl.text = text;
  }

  /// 数值展示：按精度开关输出 2 位或 5 位（toStringAsFixed 自动补 0）
  String _formatGpa(double v) =>
      _precise5 ? v.toStringAsFixed(5) : v.toStringAsFixed(2);

  // ---------- 数值解析 ----------

  /// 解析 0–4.0 的输入；空白返回 null（待输入），非法也返回 null
  double? _parseScore(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final v = double.tryParse(t);
    if (v == null || v < 0 || v > 4.0) return null;
    return v;
  }

  bool _invalidShown(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return false;
    return _parseScore(t) == null;
  }

  double? get _coreValue {
    // 自动模式下用全精度核心绩参与计算（页面展示值可能仅 2 位）
    if (!_coreCustom) {
      final grades = ref.read(gradesProvider).asData?.value;
      final gpa = grades == null ? null : CoreGpaUtil.analyze(grades).gpa;
      if (gpa != null) return gpa;
    }
    return _parseScore(_coreCtrl.text);
  }
  double? get _academicValue => _parseScore(_academicCtrl.text);
  double? get _comprehensiveValue => _parseScore(_comprehensiveCtrl.text);

  /// 当前方案计算结果（任一参与项缺失/无效时返回 null）
  double? _calcResult() {
    final scheme = _scheme;
    final core = _coreValue;
    final academic = _academicValue;
    if (scheme == null || core == null || academic == null) return null;
    if (scheme == '811') {
      final comprehensive = _comprehensiveValue;
      if (comprehensive == null) return null;
      return core * 0.8 + academic * 0.1 + comprehensive * 0.1;
    }
    if (scheme == '82') {
      return core * 0.8 + academic * 0.2;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // 成绩数据变化时同步核心绩自动值
    final gradesData = ref.watch(gradesProvider).asData?.value;
    if (gradesData != null) {
      final gpa = CoreGpaUtil.analyze(gradesData).gpa;
      final text = gpa == null ? '' : _formatGpa(gpa);
      if (_coreCtrl.text != text) _coreCtrl.text = text;
    }

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
                '根据您的实际情况计算您的 811/82 结果',
                style: TextStyle(
                  fontSize: 14,
                  color: colorScheme.onSurface.withValues(alpha: .5),
                ),
              ),
              const SizedBox(height: 20),
              _buildWarningBanner(),
              const SizedBox(height: 12),
              _buildInfoBanner(),
              const SizedBox(height: 16),
              _buildSchemeChooser(colorScheme),
              const SizedBox(height: 16),
              _buildCoreCard(colorScheme),
              const SizedBox(height: 12),
              _buildInputsRow(colorScheme),
              const SizedBox(height: 12),
              _buildResultCard(colorScheme),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 顶部提示 ----------

  /// 红色警示：结果仅作参考，需自行核对培养方案与院系方案
  Widget _buildWarningBanner() {
    return const NoteBanner.warning(
      title: '注意',
      text: '计算结果仅作为参考，请务必自行核对培养方案与院系方案的要求后再使用。',
    );
  }

  /// 蓝色提示：免试推荐适用的学业综合成绩计算范围
  Widget _buildInfoBanner() {
    return NoteBanner.info(title: '提示', text: _infoText);
  }

  // ---------- 方案单选 ----------

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
            _schemeRow(cs, value: '811', label: '811 方案', hint: '核心绩 80% + 学术 10% + 综合 10%'),
            _schemeRow(cs, value: '82', label: '82 方案', hint: '核心绩 80% + 学术 20%'),
          ],
        ),
      ),
    );
  }

  Widget _schemeRow(
    ColorScheme cs, {
    required String value,
    required String label,
    required String hint,
  }) {
    final selected = _scheme == value;
    return InkWell(
      onTap: () => setState(() => _scheme = value),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Radio<String>(value: value, activeColor: cs.primary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: cs.onSurface.withValues(alpha: selected ? .95 : .8),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              hint,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withValues(
                  alpha: selected ? .5 : .38,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 核心绩卡 ----------

  Widget _buildCoreCard(ColorScheme cs) {
    final invalid = _invalidShown(_coreCtrl.text);
    final coreCount =
        (ref.watch(gradesProvider).asData?.value == null)
        ? 0
        : CoreGpaUtil.analyze(ref.watch(gradesProvider).asData!.value).courses
              .length;
    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '核心绩',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface.withValues(alpha: .85),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: (_coreCustom ? AppTheme.warning : AppTheme.success)
                      .withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  _coreCustom ? '自定义' : '自动计算',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _coreCustom ? AppTheme.warning : AppTheme.success,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                _coreCustom
                    ? '（双击后已自定义）'
                    : '（学分加权 · 与成绩单核心绩口径一致 · $coreCount 门）',
                style: TextStyle(
                  fontSize: 11.5,
                  color: cs.onSurface.withValues(alpha: .45),
                ),
              ),
              const Spacer(),
              if (_coreCustom)
                TextButton.icon(
                  onPressed: () {
                    setState(() {
                      _coreCustom = false;
                      _coreEditing = false;
                    });
                    _syncCore();
                  },
                  icon: const Icon(Icons.undo_rounded, size: 15),
                  label: const Text(
                    '恢复自动',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onDoubleTap:
                _coreEditing || _coreCustom
                    ? null
                    : () => setState(() => _coreEditing = true),
            child: TextField(
              controller: _coreCtrl,
              enabled: _coreEditing,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              maxLength: 8,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
              decoration: InputDecoration(
                counterText: '',
                hintText: '自动计算中…（双击可自定义，0 – 4.0）',
                hintStyle: TextStyle(
                  fontSize: 13,
                  color: cs.onSurface.withValues(alpha: .35),
                ),
                errorText: invalid ? '请输入 0 – 4.0 之间的数值' : null,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) {
                if (!_coreCustom) setState(() => _coreCustom = true);
                setState(() {});
              },
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 学术 / 综合 ----------

  Widget _buildInputsRow(ColorScheme cs) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _inputCard(cs, kind: _InputKind.academic)),
        const SizedBox(width: 12),
        Expanded(child: _inputCard(cs, kind: _InputKind.comprehensive)),
      ],
    );
  }

  Widget _inputCard(ColorScheme cs, {required _InputKind kind}) {
    final isAcademic = kind == _InputKind.academic;
    final ctrl = isAcademic ? _academicCtrl : _comprehensiveCtrl;
    final enabled = isAcademic || _scheme == '811';
    final invalid = _invalidShown(ctrl.text);
    final filled = ctrl.text.trim().isNotEmpty;
    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                isAcademic ? '学术科研能力' : '综合能力',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface.withValues(
                    alpha: enabled ? .85 : .4,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                isAcademic ? '（0 – 4.0）' : '（0 – 4.0 · 仅 811 方案）',
                style: TextStyle(
                  fontSize: 11.5,
                  color: cs.onSurface.withValues(alpha: .45),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: ctrl,
            enabled: enabled,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
            ),
            maxLength: 4,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
            decoration: InputDecoration(
              counterText: '',
              hintText: enabled
                  ? (filled ? null : '如 3.70（未填则不计结果）')
                  : '综合能力不参与 82 方案',
              hintStyle: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: .35),
              ),
              errorText: invalid ? '请输入 0 – 4.0 之间的数值' : null,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
    );
  }

  // ---------- 结果卡 ----------

  Widget _buildResultCard(ColorScheme cs) {
    final result = _calcResult();
    final core = _coreValue;
    final academic = _academicValue;
    final comprehensive = _comprehensiveValue;

    final anyInvalid =
        _invalidShown(_coreCtrl.text) ||
        _invalidShown(_academicCtrl.text) ||
        _invalidShown(_comprehensiveCtrl.text);

    String formula;
    if (_scheme == null) {
      formula = '请先选择计算方案（811 / 82）';
    } else if (core != null && academic != null && _scheme == '82') {
      formula =
          '${_formatGpa(core)} × 80% + ${_formatGpa(academic)} × 20%';
    } else if (core != null && academic != null && comprehensive != null) {
      formula =
          '${_formatGpa(core)} × 80% + ${_formatGpa(academic)} × 10% + '
          '${_formatGpa(comprehensive)} × 10%';
    } else {
      formula =
          '请补齐${core == null ? '核心绩' : ''}${core == null && academic == null ? '、' : ''}'
          '${academic == null ? '学术科研能力' : ''}'
          '${(_scheme == '811' && comprehensive == null) ? (core == null || academic == null ? '、' : '') : ''}'
          '${(_scheme == '811' && comprehensive == null) ? '综合能力' : ''}${_scheme == '82' ? '' : ''}'
          '后自动出结果';
    }

    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '计算结果',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface.withValues(alpha: .85),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '5 位小数',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: .55),
                      ),
                    ),
                    Switch(
                      value: _precise5,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: (v) => setState(() => _precise5 = v),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  formula,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: cs.onSurface.withValues(alpha: .55),
                  ),
                ),
                if (anyInvalid) ...[
                  const SizedBox(height: 6),
                  Text(
                    '存在无效输入（应为 0 – 4.0），暂不出结果。',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.error,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (result != null) ...[
                Text(
                  '${_scheme ?? ''} 方案'.trim(),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: cs.onSurface.withValues(alpha: .45),
                  ),
                ),
                Text(
                  _formatGpa(result),
                  style: TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w700,
                    color: cs.primary,
                    height: 1.1,
                  ),
                ),
              ] else
                Text(
                  '--',
                  style: TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface.withValues(alpha: .2),
                    height: 1.1,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

enum _InputKind { academic, comprehensive }
