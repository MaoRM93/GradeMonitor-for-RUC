import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/network/api_client.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/toast_host.dart';
import '../../providers/grades_provider.dart';
import '../../core/service/feature_gate_service.dart';
import '../../widgets/feature_gate.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/note_banner.dart';
import 'scheme_core.dart';

/// 培养方案入口可选的年级列表（前端写死，便于后续增补）。
///
/// 与后端 `assets/curricula/*.pdf.enc` 实际部署的年级对应；开发者开关
/// `Enable_PYFA_EvyGrde` 开启时，这里每个年级都会渲染成一个独立入口。
const List<String> kCurriculumGrades = <String>['2024', '2025', '2026'];

/// 「方案计算」页：根据推免方案计算 811 / 82 结果。
///
/// 计算规则（用户给定，勿改）：
/// - 811 方案 = 核心绩×80% + 学术科研能力×10% + 素质拓展×10%
/// - 82 方案  = 核心绩×80% + 学术科研能力×20%
/// - 核心绩由 App 自动计算（白名单学分加权，见 scheme_core.dart），
///   默认只读；双击可自定义，自定义后可一键恢复自动值
/// - 学术科研能力 / 素质拓展为文本框输入，上限各 4.0
class SchemePage extends ConsumerStatefulWidget {
  const SchemePage({super.key});

  @override
  ConsumerState<SchemePage> createState() => _SchemePageState();
}

class _SchemePageState extends ConsumerState<SchemePage> {
  static const String _infoText =
      '根据 2026 年政策，本年度免试推荐适用的学业综合成绩计算范围包括思想政治理论课（含思政选修课）、'
      '公共外语/大学外语（含拓展类课程）、平台课/公共计算机、部类共同、部类基础（必修）、'
      '部类核心课、专业基础、公共数学、人工智能与数据技术平台课/数据与信息技术课、'
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
  bool _openingCurriculum = false;

  /// 开发者开关 `Enable_PYFA_EvyGrde`（1.1）：开启后不再限制账号年级，
  /// 每个已部署年级都给一个独立入口。关闭时下方渲染与历史版本完全一致。
  bool _anyGradeEnabled = false;

  String? get _curriculumGrade {
    final username = ref.read(settingsProvider).username.trim();
    final grade = username.length >= 4 ? username.substring(0, 4) : '';
    return const {'2024', '2025', '2026'}.contains(grade) ? grade : null;
  }

  Future<void> _openCurriculum() async {
    if (_curriculumGrade == null) {
      ToastHost().show('当前登录账号未匹配可用培养方案');
      return;
    }
    setState(() => _openingCurriculum = true);
    try {
      await ApiClient().openCurriculum();
      if (mounted) {
        ToastHost().show('已在浏览器中打开培养方案；如无法打开，请检查网络条件后重试。');
      }
    } catch (e) {
      if (mounted) ToastHost().show('打开失败：请检查网络条件后重试。');
    } finally {
      if (mounted) setState(() => _openingCurriculum = false);
    }
  }

  /// 指定年级打开培养方案（仅开关 1.1 开启时可用）。
  Future<void> _openCurriculumForGrade(String grade) async {
    setState(() => _openingCurriculum = true);
    try {
      await ApiClient().openCurriculum(grade: grade);
      if (mounted) {
        ToastHost().show('已在浏览器中打开 $grade 级培养方案；如无法打开，请检查网络条件后重试。');
      }
    } catch (e) {
      if (mounted) ToastHost().show('打开失败：请检查网络条件后重试。');
    } finally {
      if (mounted) setState(() => _openingCurriculum = false);
    }
  }

  /// 读取开发者开关（失败按"关闭"处理，保持历史行为）。
  Future<void> _loadFlags() async {
    try {
      final r = await ApiClient().getDeveloperFlags();
      final raw = r.data is Map ? r.data['flags'] : null;
      if (!mounted || raw is! Map) return;
      final on = raw['Enable_PYFA_EvyGrde'] == true;
      if (on != _anyGradeEnabled) setState(() => _anyGradeEnabled = on);
    } catch (_) {
      // 静默：读不到开关时退回原有单按钮逻辑
    }
  }

  @override
  void initState() {
    super.initState();
    // 首次加载：从已缓存的成绩数据同步核心绩自动值
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncCore());
    _loadFlags();
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

  /// 是否已勾选方案：未选（null）时下方三块进入置灰禁用态
  bool get _hasSelection => _scheme != null;

  /// 灰度矩阵：把任意前景色（含主题主色、红/绿语义色）压成同亮度灰，
  /// 这样置灰不依赖硬编码黑白，深浅色主题都成立。
  static const ColorFilter _grayscale = ColorFilter.matrix(<double>[
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0, 0, 0, 1, 0, //
  ]);

  /// 整块置灰 + 屏蔽交互（不改布局尺寸、不禁用外层滚动）：
  /// ColorFiltered 去色 + Opacity 降不透明度，再用 IgnorePointer 只挡这一块的手势。
  Widget _dimBlock(Widget child) {
    if (_hasSelection) return child;
    return IgnorePointer(
      ignoring: true, // 未选方案：这三块不吃手势（外层滚动不受影响）
      child: ColorFiltered(
        colorFilter: _grayscale,
        child: Opacity(opacity: .45, child: child),
      ),
    );
  }

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

    // 成绩数据变化时同步核心绩自动值（自动模式下才允许覆盖）
    if (!_coreCustom && !_coreEditing) {
      final gradesData = ref.watch(gradesProvider).asData?.value;
      if (gradesData != null) {
        final gpa = CoreGpaUtil.analyze(gradesData).gpa;
        final text = gpa == null ? '' : _formatGpa(gpa);
        if (_coreCtrl.text != text) _coreCtrl.text = text;
      }
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
                  fontFamily: AppTheme.serifFontFamily,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 10),
              // 开关 1.1 关闭：保持历史单按钮与禁用逻辑（账号年级不匹配即禁用）；
              // 开关开启：每个已部署年级一个入口，全部可点。
              // Flag-1024：整个培养方案入口可被远程静默下线。
              if (!featureEnabled(FeatureGateService.flag1024Curriculum))
                const SizedBox.shrink()
              else if (_anyGradeEnabled)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final grade in kCurriculumGrades)
                      OutlinedButton.icon(
                        onPressed: _openingCurriculum
                            ? null
                            : () => _openCurriculumForGrade(grade),
                        icon: _openingCurriculum
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.menu_book_outlined, size: 18),
                        label: Text('查看 $grade 级培养方案 ↗'),
                      ),
                  ],
                )
              else
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _openingCurriculum || _curriculumGrade == null
                        ? null
                        : _openCurriculum,
                    icon: _openingCurriculum
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.menu_book_outlined, size: 18),
                    label: Text(
                      _curriculumGrade == null
                          ? '当前账号暂无匹配培养方案'
                          : '查看 ${_curriculumGrade!} 级培养方案 ↗',
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              _buildWarningBanner(),
              const SizedBox(height: 12),
              _buildInfoBanner(),
              const SizedBox(height: 16),
              FeatureGate(
                flag: FeatureGateService.flag1020SchemeChooser,
                child: _buildSchemeChooser(colorScheme),
              ),
              const SizedBox(height: 16),
              _buildInputsRow(colorScheme),
              const SizedBox(height: 16),
              // Flag-1023：计算结果卡可被远程静默下线
              FeatureGate(
                flag: FeatureGateService.flag1023Result,
                child: _dimBlock(_buildResultCard(colorScheme)),
              ),
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
      persistKey: 'scheme_result_warning',
      title: '注意',
      text: '计算结果仅作为参考，请务必自行核对培养方案与院系方案的要求后再使用。',
    );
  }

  /// 蓝色提示：免试推荐适用的学业综合成绩计算范围
  Widget _buildInfoBanner() {
    return NoteBanner.info(persistKey: 'scheme_scope_info', text: _infoText);
  }

  // ---------- 方案单选 ----------

  Widget _buildSchemeChooser(ColorScheme cs) {
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '方案',
            style: TextStyle(
              fontFamily: AppTheme.serifFontFamily,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: cs.onSurface.withValues(alpha: .85),
            ),
          ),
          const SizedBox(height: 4),
          RadioGroup<String>(
            groupValue: _scheme,
            onChanged: (v) {
              if (v != null && v != _scheme) {
                setState(() => _scheme = v);
              }
            },
            child: Row(
              children: [
                Expanded(child: _schemeCell(cs, value: '811')),
                const SizedBox(width: 10),
                Expanded(child: _schemeCell(cs, value: '82')),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 单个方案选择块（两列布局，选中态淡色高亮、无边框）
  Widget _schemeCell(ColorScheme cs, {required String value}) {
    final selected = _scheme == value;
    return InkWell(
      onTap: () => setState(() => _scheme = value),
      borderRadius: AppShape.inner,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          borderRadius: AppShape.inner,
          color: selected
              ? cs.primary.withValues(alpha: .07)
              : Colors.transparent,
        ),
        child: Row(
          children: [
            Radio<String>(value: value, activeColor: cs.primary),
            const SizedBox(width: 4),
            Text(
              value == '811' ? '811 政策' : '82 政策',
              style: TextStyle(
                fontSize: 15,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: cs.onSurface.withValues(alpha: selected ? .95 : .8),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 核心绩卡 ----------

  Widget _buildCoreCard(ColorScheme cs, {required BorderRadius radius}) {
    final invalid = _invalidShown(_coreCtrl.text);
    return GlassCard(
      shape: radius,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '核心绩',
                style: TextStyle(
                  fontFamily: AppTheme.serifFontFamily,
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
                  borderRadius: AppShape.inner,
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
              const Spacer(),
              if (_coreCustom || _coreEditing)
                TextButton(
                  onPressed: () {
                    setState(() {
                      _coreCustom = false;
                      _coreEditing = false;
                    });
                    _syncCore();
                  },
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(0, 22),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('恢复自动', style: TextStyle(fontSize: 11.5)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(child: _buildCoreInput(cs, invalid: invalid)),
        ],
      ),
    );
  }

  /// 核心绩输入：未编辑态渲染纯文本（无边框文本框，双击进入编辑态）。
  /// 不能用 enabled:false 的 TextField——其内部 IgnorePointer 会吞掉
  /// 双击手势，导致自定义功能失效。
  Widget _buildCoreInput(ColorScheme cs, {required bool invalid}) {
    if (!_coreEditing) {
      final value = _coreCtrl.text.trim();
      return InkWell(
        onDoubleTap: () => setState(() => _coreEditing = true),
        borderRadius: AppShape.inner,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value.isEmpty ? '自动计算中…' : value,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: value.isEmpty
                    ? cs.onSurface.withValues(alpha: .35)
                    : cs.onSurface,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '双击可自定义',
              style: TextStyle(
                fontSize: 11.5,
                color: cs.onSurface.withValues(alpha: .35),
              ),
            ),
          ],
        ),
      );
    }
    return TextField(
      controller: _coreCtrl,
      autofocus: true,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      textAlignVertical: TextAlignVertical.center,
      maxLength: 8,
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: cs.onSurface,
      ),
      decoration: InputDecoration(
        counterText: '',
        hintText: '0 – 4.0',
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
      ),
      onChanged: (_) => setState(() {
        _coreCustom = true;
      }),
    );
  }

  // ---------- 核心绩 / 学术 / 素质拓展（三卡一行，等高） ----------

  Widget _buildInputsRow(ColorScheme cs) {
    // Flag-1021 / Flag-1022 可分别下线"核心绩卡"与"学术+综合素质两卡"。
    // 三卡原本等宽等高，被下线后剩下的卡自动均分宽度，不留空位。
    final showCore = featureEnabled(FeatureGateService.flag1021CoreCard);
    final showManual = featureEnabled(FeatureGateService.flag1022Inputs);

    // 三张卡横向拼成一个整体：只有最左卡的左上/左下与最右卡的右上/右下
    // 是大圆角，中间卡与朝向内部的角一律小圆角（Material 3 Expressive 的
    // 分组形状层级）。被 Flag 下线时首尾自动重算，不会留错角。
    final specs = <_InputCardSpec>[
      if (showCore) const _InputCardSpec(_InputKind.core),
      if (showManual) const _InputCardSpec(_InputKind.academic),
      if (showManual) const _InputCardSpec(_InputKind.comprehensive),
    ];
    if (specs.isEmpty) return const SizedBox.shrink();
    final cards = <Widget>[
      for (var i = 0; i < specs.length; i++)
        Expanded(
          child: _dimBlock(
            _inputCard(
              cs,
              kind: specs[i].kind,
              radius: AppShape.gridRow(
                first: i == 0,
                last: i == specs.length - 1,
              ),
            ),
          ),
        ),
    ];

    // 先用 IntrinsicHeight 把行高定为最高子卡的高度，再 stretch 各卡等高
    //（滚动上下文里直接 stretch 会给子项无界高度，必须先定高）
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            // 组内缝隙只露一线路底色，让三卡在视觉上拼成一个整体
            if (i > 0) const SizedBox(width: AppShape.gapInner),
            cards[i],
          ],
        ],
      ),
    );
  }

  Widget _inputCard(
    ColorScheme cs, {
    required _InputKind kind,
    required BorderRadius radius,
  }) {
    if (kind == _InputKind.core) return _buildCoreCard(cs, radius: radius);
    final isAcademic = kind == _InputKind.academic;
    final ctrl = isAcademic ? _academicCtrl : _comprehensiveCtrl;
    final enabled = isAcademic || _scheme == '811';
    final invalid = _invalidShown(ctrl.text);
    return GlassCard(
      shape: radius,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isAcademic ? '学术科研能力' : '素质拓展能力',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withValues(alpha: enabled ? .85 : .4),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TextField(
              controller: ctrl,
              enabled: enabled,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textAlignVertical: TextAlignVertical.center,
              maxLength: 4,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
              decoration: InputDecoration(
                counterText: '',
                hintText: enabled ? '0 – 4.0' : '素质拓展能力不参与 82 方案',
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
              ),
              onChanged: (_) => setState(() {}),
            ),
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
      formula = '${_formatGpa(core)} × 80% + ${_formatGpa(academic)} × 20%';
    } else if (core != null && academic != null && comprehensive != null) {
      formula =
          '${_formatGpa(core)} × 80% + ${_formatGpa(academic)} × 10% + '
          '${_formatGpa(comprehensive)} × 10%';
    } else {
      formula =
          '请补齐${core == null ? '核心绩' : ''}${core == null && academic == null ? '、' : ''}'
          '${academic == null ? '学术科研能力' : ''}'
          '${(_scheme == '811' && comprehensive == null) ? (core == null || academic == null ? '、' : '') : ''}'
          '${(_scheme == '811' && comprehensive == null) ? '素质拓展能力' : ''}${_scheme == '82' ? '' : ''}'
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
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '计算结果',
                      style: TextStyle(
                        fontFamily: AppTheme.serifFontFamily,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface.withValues(alpha: .85),
                      ),
                    ),
                    const SizedBox(width: 14),
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: Checkbox(
                        value: _precise5,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: (v) =>
                            setState(() => _precise5 = v ?? false),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '精确计算',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: .55),
                      ),
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

enum _InputKind { core, academic, comprehensive }

/// 三卡一行里的一个位置：只用来承载顺序，圆角由所在位置推导。
class _InputCardSpec {
  const _InputCardSpec(this.kind);
  final _InputKind kind;
}
