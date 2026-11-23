import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/service/feature_gate_service.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/grades_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/feature_gate.dart';
import '../../widgets/beta_badge.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/note_banner.dart';
import '../../widgets/toast_host.dart';
import '../scheme/scheme_page.dart' show kCurriculumGrades;
import 'major_picker.dart';
import 'progress_core.dart';
import 'progress_store.dart';

/// 「修读进度」页：把成绩单摊到培养方案的模块与子项上，算出学分进度。
///
/// 三层数据：成绩单（kcname/xf/kclbname/zcj）、本地解释（类别覆盖 + 实践项勾选
/// + 自定义组合）、培养方案（assets/curricula/curriculum_plan.json，离线构建产物）。
class ProgressPage extends ConsumerStatefulWidget {
  const ProgressPage({super.key});

  @override
  ConsumerState<ProgressPage> createState() => _ProgressPageState();
}

class _ProgressPageState extends ConsumerState<ProgressPage> {
  static const String _feedbackUrl = 'https://v.wjx.cn/vm/ObkWPDK.aspx#';

  CurriculumPlan? _plan;
  String? _year;

  /// 为空表示用户还没选专业——此时不出任何进度数据。
  String? _majorName;
  ProgressState _state = ProgressState();
  bool _loading = true;
  bool _beta = false;
  Timer? _saveTimer;
  final _noteCtrl = TextEditingController();

  /// 培养方案 PDF 入口的打开中状态，与「方案计算」页同一套按钮逻辑。
  bool _openingCurriculum = false;

  /// 开发者开关 `Enable_PYFA_EvyGrde`（1.1）：开启后每个年级各给一个入口。
  bool _anyGradeEnabled = false;

  /// 已展开的子项 key（`模块/子项`），默认全部收起。
  final Set<String> _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    _boot();
    _loadFlags();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _noteCtrl.dispose();
    super.dispose();
  }

  /// 换年级/专业后把文本框内容同步成新记录，避免显示上一份的备注。
  void _syncNote() {
    if (_noteCtrl.text != _state.note) _noteCtrl.text = _state.note;
  }

  Future<void> _boot() async {
    final plan = await CurriculumPlan.load();
    final username = ref.read(settingsProvider).username.trim();
    final grade = username.length >= 4 ? username.substring(0, 4) : '';
    final years = plan.gradeList;
    final year = years.contains(grade)
        ? grade
        : (years.isNotEmpty ? years.last : '');
    final beta = ProgressStore.loadAdvancedClassify();
    if (year.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final majors = plan.years[year] ?? const <PlanMajor>[];
    final saved = ProgressStore.loadMajor(year);
    // 记住上次选的专业，但**不**替用户挑一个：没选过就是没选。
    final majorName = majors.any((m) => m.name == saved) ? saved : null;
    final state = majorName == null
        ? ProgressState()
        : ProgressStore.load(year, majorName);
    if (!mounted) return;
    setState(() {
      _plan = plan;
      _year = year;
      _majorName = majorName;
      _state = state;
      _beta = beta;
      _loading = false;
    });
    _syncNote();
    // 成绩单可能还没被别的页面拉过，这里补一次；已有数据则不重置。
    if (ref.read(gradesProvider) is! AsyncData) {
      Future.microtask(() => ref.read(gradesProvider.notifier).fetchGrades());
    }
  }

  void _switchYear(String year) {
    final plan = _plan;
    if (plan == null) return;
    final majors = plan.years[year] ?? const <PlanMajor>[];
    final saved = ProgressStore.loadMajor(year);
    final majorName = majors.any((m) => m.name == saved) ? saved : null;
    setState(() {
      _year = year;
      _majorName = majorName;
      _state = majorName == null
          ? ProgressState()
          : ProgressStore.load(year, majorName);
      _expanded.clear();
    });
    _syncNote();
  }

  Future<void> _pickMajor() async {
    final year = _year;
    final plan = _plan;
    if (year == null || plan == null) return;
    final majors = plan.years[year] ?? const <PlanMajor>[];
    if (majors.isEmpty) return;
    final picked = await showMajorPicker(
      context,
      majors: [for (final m in majors) m.name],
      current: _majorName,
    );
    if (picked == null || picked == _majorName) return;
    setState(() {
      _majorName = picked;
      _state = ProgressStore.load(year, picked);
      _expanded.clear();
    });
    _syncNote();
    ProgressStore.saveMajor(year, picked);
  }

  /// 写盘做防抖：勾选与文本框都会高频触发，避免每次按键都落一次文件。
  void _persist() {
    final year = _year;
    final major = _majorName;
    if (year == null || major == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 350), () {
      ProgressStore.save(year, major, _state);
    });
  }

  void _setOverride(String kth, String? key) {
    setState(() {
      if (key == null) {
        _state.overrides.remove(kth);
      } else {
        _state.overrides[kth] = key;
      }
    });
    _persist();
  }

  void _toggleManual(String key, bool value) {
    setState(() => _state.manual[key] = value);
    _persist();
  }

  void _toggleExpanded(String key) {
    setState(() {
      if (!_expanded.remove(key)) _expanded.add(key);
    });
  }

  void _setBeta(bool value) {
    setState(() => _beta = value);
    ProgressStore.saveAdvancedClassify(value);
  }

  Future<void> _openFeedback() async {
    try {
      if (Platform.isMacOS) {
        await Process.start('open', <String>[_feedbackUrl]);
      } else if (Platform.isWindows) {
        await Process.start('cmd', <String>['/c', 'start', '', _feedbackUrl]);
      } else {
        await Process.start('xdg-open', <String>[_feedbackUrl]);
      }
    } catch (_) {
      ToastHost().show('无法打开链接');
    }
  }

  // ---------- 培养方案 PDF 入口（与「方案计算」页同一套规则） ----------

  /// 账号年级：取学号前四位，只认已部署的年级。
  String? get _curriculumGrade {
    final username = ref.read(settingsProvider).username.trim();
    final grade = username.length >= 4 ? username.substring(0, 4) : '';
    return kCurriculumGrades.contains(grade) ? grade : null;
  }

  Future<void> _openCurriculum() async {
    final grade = _curriculumGrade;
    if (grade == null) {
      ToastHost().show('当前登录账号未匹配可用培养方案');
      return;
    }
    setState(() => _openingCurriculum = true);
    try {
      await ApiClient().openCurriculum();
      if (mounted) {
        ToastHost().show('已在浏览器中打开培养方案；如无法打开，请检查网络条件后重试。');
      }
    } catch (_) {
      if (mounted) ToastHost().show('打开失败：请检查网络条件后重试。');
    } finally {
      if (mounted) setState(() => _openingCurriculum = false);
    }
  }

  /// 指定年级打开培养方案（仅开发者开关 1.1 开启时可用）。
  Future<void> _openCurriculumForGrade(String grade) async {
    setState(() => _openingCurriculum = true);
    try {
      await ApiClient().openCurriculum(grade: grade);
      if (mounted) {
        ToastHost().show('已在浏览器中打开 $grade 级培养方案；如无法打开，请检查网络条件后重试。');
      }
    } catch (_) {
      if (mounted) ToastHost().show('打开失败：请检查网络条件后重试。');
    } finally {
      if (mounted) setState(() => _openingCurriculum = false);
    }
  }

  /// 读开发者开关；失败按关闭处理，保持与方案计算页一致的单按钮行为。
  Future<void> _loadFlags() async {
    try {
      final r = await ApiClient().getDeveloperFlags();
      final raw = r.data is Map ? r.data['flags'] : null;
      if (!mounted || raw is! Map) return;
      final on = raw['Enable_PYFA_EvyGrde'] == true;
      if (on != _anyGradeEnabled) setState(() => _anyGradeEnabled = on);
    } catch (_) {
      // 静默：读不到就退回单按钮
    }
  }

  /// 培养方案 PDF 入口。显示规则逐条照搬「方案计算」页：
  /// Flag-1024 关闭则整块隐藏；开发者开关 1.1 开启则每个年级一个入口；
  /// 否则只给当前账号年级一个入口，年级不匹配则禁用。
  Widget _buildCurriculumEntry() {
    if (!featureEnabled(FeatureGateService.flag1024Curriculum)) {
      return const SizedBox.shrink();
    }
    if (_anyGradeEnabled) {
      return Wrap(
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
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.menu_book_outlined, size: 18),
              label: Text('查看 $grade 级培养方案 ↗'),
            ),
        ],
      );
    }
    final grade = _curriculumGrade;
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        onPressed: _openingCurriculum || grade == null ? null : _openCurriculum,
        icon: _openingCurriculum
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.menu_book_outlined, size: 18),
        label: Text(grade == null ? '当前账号暂无匹配培养方案' : '查看 $grade 级培养方案 ↗'),
      ),
    );
  }

  PlanMajor? get _major {
    final plan = _plan;
    final year = _year;
    final name = _majorName;
    if (plan == null || year == null || name == null) return null;
    for (final m in plan.years[year] ?? const <PlanMajor>[]) {
      if (m.name == name) return m;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final gradesAsync = ref.watch(gradesProvider);
    final major = _major;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 44, 28, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    '修读进度',
                    style: TextStyle(
                      fontFamily: AppTheme.serifFontFamily,
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const BetaBadge(fontSize: 12),
                ],
              ),
              const SizedBox(height: 14),
              // 培养方案 PDF 入口：与「方案计算」页共用同一套按钮与显示规则。
              _buildCurriculumEntry(),
              const SizedBox(height: 14),
              // 合规提示常驻：不给「不再显示」也不给「叉」。
              NoteBanner.warning(
                persistKey: 'progress_disclaimer',
                dismissible: false,
                text:
                    '下列进度仅供参考，请务必手动核对培养方案的要求，'
                    '避免影响您的学业。如您发现错漏，请联系开发者↗便于我们尽快修复错误。',
                linkText: '联系开发者↗',
                onLinkTap: _openFeedback,
              ),
              const SizedBox(height: 16),
              _buildSelectors(cs),
              const SizedBox(height: 16),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_year == null)
                _hint(cs, '当前账号没有匹配到培养方案年级')
              else if (major == null)
                _buildEmpty(cs)
              else ...[
                FeatureGate(
                  flag: FeatureGateService.flag1026ProgressBeta,
                  child: _buildBetaSwitch(cs),
                ),
                ..._buildBody(cs, major, gradesAsync),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 年级 / 专业 ----------

  Widget _buildSelectors(ColorScheme cs) {
    final plan = _plan;
    final years = plan?.gradeList ?? const <String>[];
    return Row(
      children: [
        _selector(
          cs,
          label: '年级',
          child: DropdownButton<String>(
            value: _year,
            style: _dropdownStyle(cs),
            dropdownColor: cs.surfaceContainerHighest,
            menuMaxHeight: 300,
            isExpanded: true,
            alignment: AlignmentDirectional.centerStart,
            underline: const SizedBox(),
            isDense: true,
            items: [
              for (final y in years)
                DropdownMenuItem(value: y, child: Text('$y 级')),
            ],
            onChanged: (v) {
              if (v != null && v != _year) _switchYear(v);
            },
          ),
        ),
        const SizedBox(width: AppShape.gapGroup),
        Expanded(
          child: _selector(
            cs,
            label: '专业',
            child: InkWell(
              onTap: _pickMajor,
              borderRadius: AppShape.inner,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _majorName ?? '选择专业',
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: _dropdownStyle(cs).copyWith(
                        color: _majorName == null
                            ? cs.onSurface.withValues(alpha: .5)
                            : cs.onSurface,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.unfold_more,
                    size: 16,
                    color: cs.onSurface.withValues(alpha: .5),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _selector(
    ColorScheme cs, {
    required String label,
    required Widget child,
  }) {
    final box = Container(
      height: 40,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: AppShape.insetFill(cs),
        borderRadius: AppShape.inner,
      ),
      child: child,
    );
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontFamily: AppTheme.sansFontFamily,
              fontSize: 14,
              color: cs.onSurface.withValues(alpha: .6),
            ),
          ),
          const SizedBox(width: 6),
          // 年级只有三个选项，定宽即可；专业名长度差异大，必须吃掉剩余宽度。
          if (label == '年级')
            SizedBox(width: 128, child: box)
          else
            Expanded(child: box),
        ],
      ),
    );
  }

  TextStyle _dropdownStyle(ColorScheme cs) => TextStyle(
    fontFamily: AppTheme.sansFontFamily,
    fontSize: 13,
    color: cs.onSurface,
  );

  Widget _hint(ColorScheme cs, String text) {
    return GlassCard(
      child: Text(text, style: TextStyle(fontSize: 14, color: cs.onSurface)),
    );
  }

  Widget _buildEmpty(ColorScheme cs) {
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '先选择专业，再查看修读进度',
            style: TextStyle(
              fontFamily: AppTheme.serifFontFamily,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withValues(alpha: .85),
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _pickMajor,
            icon: const Icon(Icons.search, size: 16),
            label: const Text('选择专业'),
          ),
        ],
      ),
    );
  }

  Widget _buildBetaSwitch(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppShape.gapGroup),
      child: GlassCard(
        padding: const EdgeInsets.fromLTRB(20, 6, 12, 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '高级分类（Beta）',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurface.withValues(alpha: .8),
                ),
              ),
            ),
            Switch(
              value: _beta,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: _setBeta,
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 主体 ----------

  List<Widget> _buildBody(
    ColorScheme cs,
    PlanMajor major,
    AsyncValue<List<GradeCourse>> gradesAsync,
  ) {
    final grades = gradesAsync.asData?.value ?? const <GradeCourse>[];
    final result = computeProgress(
      major: major,
      grades: grades,
      overrides: _state.overrides,
      manual: _state.manual,
      rules: _state.rules,
    );

    return <Widget>[
      _buildOverall(cs, result),
      const SizedBox(height: AppShape.gapGroup),
      for (final module in result.modules) ...[
        _buildModule(cs, module),
        const SizedBox(height: AppShape.gapGroup),
      ],
      if (result.unmatched.isNotEmpty) ...[
        _buildUnmatched(cs, major, result.unmatched),
        const SizedBox(height: AppShape.gapGroup),
      ],
      _buildRules(cs, major, grades),
      const SizedBox(height: AppShape.gapGroup),
      _buildNote(cs),
    ];
  }

  Widget _buildOverall(ColorScheme cs, ProgressResult result) {
    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      result.major.name,
                      style: TextStyle(
                        fontFamily: AppTheme.serifFontFamily,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface.withValues(alpha: .85),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${_fmt(result.earned)} / ${_fmt(result.required)}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface.withValues(alpha: .7),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _bar(cs, result.ratio),
                if (result.unmatched.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    '待归类 ${result.unmatched.length} 门课程',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.warning,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 20),
          Text(
            '${(result.ratio * 100).toStringAsFixed(1)}%',
            style: TextStyle(
              fontSize: 40,
              fontWeight: FontWeight.w700,
              color: cs.primary,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }

  /// 模块内的段间距：只留 5px，让页面底色透出来形成细分割，不画线。
  static const double _segmentGap = 5;

  /// 一个模块 = 一串纵向相接的分段。
  ///
  /// 首段是模块名与进度条，其余每段是一个子项；段与段之间只留
  /// [_segmentGap] 的底色缝隙，圆角按位置自适应（首段上大下小、中间段四角
  /// 全小、末段上小下大），整串读起来是一个整体而不是若干张悬浮卡片。
  Widget _buildModule(ColorScheme cs, ModuleProgress module) {
    final segments = <Widget>[
      _moduleHeader(cs, module),
      for (final item in module.items) _buildItem(cs, item),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < segments.length; i++) ...[
          if (i > 0) const SizedBox(height: _segmentGap),
          _segment(
            cs,
            shape: AppShape.segmented(
              first: i == 0,
              last: i == segments.length - 1,
            ),
            child: segments[i],
          ),
        ],
      ],
    );
  }

  /// 分段的外壳：只有底色与自适应圆角，没有描边和阴影。
  Widget _segment(
    ColorScheme cs, {
    required BorderRadius shape,
    required Widget child,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: AppShape.groupFill(cs),
        borderRadius: shape,
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  Widget _moduleHeader(ColorScheme cs, ModuleProgress module) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                module.module.name,
                style: TextStyle(
                  fontFamily: AppTheme.serifFontFamily,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface.withValues(alpha: .85),
                ),
              ),
              const SizedBox(width: 8),
              if (module.satisfied)
                Icon(Icons.check_circle, size: 16, color: AppTheme.success),
              const Spacer(),
              Text(
                '${_fmt(module.earned)} / ${_fmt(module.required)}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface.withValues(alpha: .7),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _bar(cs, module.ratio),
        ],
      ),
    );
  }

  Widget _buildItem(ColorScheme cs, ItemProgress item) {
    final satisfied = item.satisfied;
    final expanded = _expanded.contains(item.key);
    final canExpand = item.courses.isNotEmpty;
    return InkWell(
      onTap: canExpand ? () => _toggleExpanded(item.key) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 7, 20, 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _stateIcon(cs, item),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: satisfied ? FontWeight.w600 : FontWeight.w500,
                      color: cs.onSurface.withValues(
                        alpha: satisfied ? .9 : .72,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  _itemLabel(item),
                  style: TextStyle(
                    fontSize: 12.5,
                    color: satisfied
                        ? AppTheme.success
                        : cs.onSurface.withValues(alpha: .55),
                  ),
                ),
                if (canExpand) ...[
                  const SizedBox(width: 6),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: cs.onSurface.withValues(alpha: .45),
                  ),
                ],
              ],
            ),
            if (canExpand && expanded)
              Padding(
                padding: const EdgeInsets.only(left: 24, top: 6),
                child: _buildCourseGroups(cs, item),
              ),
          ],
        ),
      ),
    );
  }

  /// 状态图标：修满打勾；修了没修满画圆圈；一门都没修才是横线。
  Widget _stateIcon(ColorScheme cs, ItemProgress item) {
    if (item.manualCapable) {
      return SizedBox(
        width: 20,
        height: 20,
        child: Checkbox(
          value: item.manualDone,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onChanged: (v) => _toggleManual(item.key, v ?? false),
        ),
      );
    }
    if (item.satisfied) {
      return Icon(Icons.check, size: 16, color: AppTheme.success);
    }
    if (item.partial) {
      return Icon(
        Icons.radio_button_unchecked,
        size: 15,
        color: cs.onSurface.withValues(alpha: .5),
      );
    }
    return Icon(
      Icons.remove,
      size: 16,
      color: cs.onSurface.withValues(alpha: .3),
    );
  }

  /// 展开后的课程明细：多个分组时先给分组标题，单组时直接平铺。
  Widget _buildCourseGroups(ColorScheme cs, ItemProgress item) {
    final groups = <String, List<GradeCourse>>{};
    for (final course in item.courses) {
      final label = courseGroupLabel(course, item.item.name, _beta);
      groups.putIfAbsent(label, () => <GradeCourse>[]).add(course);
    }
    final entries = groups.entries.toList()
      ..sort((a, b) {
        int rank(String s) => s.startsWith('自选') ? 2 : (s == '必修' ? 0 : 1);
        final byRank = rank(a.key).compareTo(rank(b.key));
        return byRank != 0 ? byRank : a.key.compareTo(b.key);
      });
    final showHeaders = entries.length > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in entries) ...[
          if (showHeaders)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 2),
              child: Row(
                children: [
                  Text(
                    entry.key,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface.withValues(alpha: .55),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${_fmt(_sumCredits(entry.value))} 学分',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: cs.onSurface.withValues(alpha: .4),
                    ),
                  ),
                ],
              ),
            ),
          for (final course in entry.value) _buildCourseRow(cs, course),
        ],
      ],
    );
  }

  Widget _buildCourseRow(ColorScheme cs, GradeCourse course) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              course.kcname,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withValues(alpha: .62),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            _scoreLabel(course),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withValues(alpha: .55),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 未归类课程 ----------

  Widget _buildUnmatched(
    ColorScheme cs,
    PlanMajor major,
    List<GradeCourse> courses,
  ) {
    final options = itemOptions(major);
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '未归类课程',
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
                  color: AppTheme.warning.withValues(alpha: .12),
                  borderRadius: AppShape.inner,
                ),
                child: Text(
                  '可能需要更改课程类别',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.warning,
                  ),
                ),
              ),
            ],
          ),
          for (final course in courses)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      course.kcname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: cs.onSurface),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${course.xf} 学分',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: cs.onSurface.withValues(alpha: .55),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 220,
                    child: _itemDropdown(
                      cs,
                      value: _state.overrides[course.kth],
                      hint: '选择类别',
                      options: options,
                      onChanged: (v) => _setOverride(course.kth, v),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ---------- 自定义组合 ----------

  Widget _buildRules(
    ColorScheme cs,
    PlanMajor major,
    List<GradeCourse> grades,
  ) {
    final options = itemOptions(major);
    final lefts = <String>{
      for (final course in grades) course.kcname.trim(),
      for (final course in grades) course.kclbname.trim(),
    }.where((s) => s.isNotEmpty).toList()..sort();
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '自定义组合',
            style: TextStyle(
              fontFamily: AppTheme.serifFontFamily,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withValues(alpha: .85),
            ),
          ),
          for (final rule in _state.rules)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  Expanded(child: _ruleText(cs, rule.left)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Text(
                      '=',
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: .5),
                      ),
                    ),
                  ),
                  Expanded(
                    child: _ruleText(cs, _optionLabel(options, rule.right)),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    onPressed: () {
                      setState(() => _state.rules.remove(rule));
                      _persist();
                    },
                    icon: const Icon(Icons.close, size: 16),
                    tooltip: '删除',
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              children: [
                Expanded(
                  child: _ruleDropdown(
                    cs,
                    hint: '选择课程或类别',
                    value: null,
                    items: lefts,
                    onChanged: (v) async {
                      final left = v == _customSentinel
                          ? await _askText('输入课程名或类别名')
                          : v;
                      if (left == null || left.isEmpty) return;
                      _addRule(left, options);
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    '=',
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurface.withValues(alpha: .5),
                    ),
                  ),
                ),
                Expanded(
                  child: _ruleDropdown(
                    cs,
                    hint: '选择培养方案子项',
                    value: null,
                    items: [for (final o in options) o.key],
                    labelOf: (key) => _optionLabel(options, key),
                    onChanged: (v) async {
                      final right = v == _customSentinel
                          ? await _askText('输入培养方案子项名')
                          : v;
                      if (right == null || right.isEmpty) return;
                      _addRule(_pendingLeft, options, right: right);
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static const String _customSentinel = '\u0000custom';

  /// 左框已选、右框还没选时的暂存值：`（）=（右）` 这一半要能跨两次选择拼起来。
  String _pendingLeft = '';

  void _addRule(String left, List<ItemOption> options, {String? right}) {
    if (right == null) {
      // 只选了左边：记下来，等右框补齐。
      _pendingLeft = left;
      setState(() {});
      return;
    }
    final resolved = _resolveRight(right, options);
    if (resolved == null) {
      ToastHost().show('没有匹配的培养方案子项');
      return;
    }
    setState(() {
      _state.rules.removeWhere((r) => r.left == left);
      _state.rules.add(CustomRule(left: left, right: resolved));
      _pendingLeft = '';
    });
    _persist();
  }

  /// 右框允许自由输入：先按 key 精确匹配，再按「模块 · 子项」或裸子项名兜底。
  String? _resolveRight(String raw, List<ItemOption> options) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    for (final o in options) {
      if (o.key == text) return o.key;
    }
    for (final o in options) {
      if ('${o.module} · ${o.item}' == text) return o.key;
    }
    final hits = options.where((o) => o.item == text).toList();
    if (hits.length == 1) return hits.first.key;
    return null;
  }

  Future<String?> _askText(String title) async {
    final ctrl = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 15)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(fontSize: 13),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return value;
  }

  String _optionLabel(List<ItemOption> options, String key) {
    for (final o in options) {
      if (o.key == key) return '${o.module} · ${o.item}';
    }
    return key;
  }

  Widget _ruleText(ColorScheme cs, String text) {
    return Container(
      height: 36,
      alignment: AlignmentDirectional.centerStart,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: AppShape.insetFill(cs),
        borderRadius: AppShape.inner,
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12.5, color: cs.onSurface),
      ),
    );
  }

  Widget _ruleDropdown(
    ColorScheme cs, {
    required String hint,
    required String? value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
    String Function(String)? labelOf,
  }) {
    return Container(
      height: 40,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: AppShape.insetFill(cs),
        borderRadius: AppShape.inner,
      ),
      child: DropdownButton<String>(
        value: value,
        hint: Text(
          hint,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12.5,
            color: cs.onSurface.withValues(alpha: .45),
          ),
        ),
        style: _dropdownStyle(cs),
        dropdownColor: cs.surfaceContainerHighest,
        menuMaxHeight: 320,
        isExpanded: true,
        alignment: AlignmentDirectional.centerStart,
        underline: const SizedBox(),
        isDense: true,
        items: [
          for (final item in items)
            DropdownMenuItem(
              value: item,
              child: Text(
                labelOf == null ? item : labelOf(item),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          DropdownMenuItem(
            value: _customSentinel,
            child: Text(
              '自定义…',
              style: TextStyle(
                fontSize: 12.5,
                color: cs.onSurface.withValues(alpha: .6),
              ),
            ),
          ),
        ],
        onChanged: onChanged,
      ),
    );
  }

  Widget _itemDropdown(
    ColorScheme cs, {
    required String? value,
    required String hint,
    required List<ItemOption> options,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      height: 36,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: AppShape.insetFill(cs),
        borderRadius: AppShape.inner,
      ),
      child: DropdownButton<String>(
        value: value,
        hint: Text(
          hint,
          style: TextStyle(
            fontSize: 12.5,
            color: cs.onSurface.withValues(alpha: .45),
          ),
        ),
        style: _dropdownStyle(cs),
        dropdownColor: cs.surfaceContainerHighest,
        menuMaxHeight: 320,
        isExpanded: true,
        alignment: AlignmentDirectional.centerStart,
        underline: const SizedBox(),
        isDense: true,
        items: [
          for (final o in options)
            DropdownMenuItem(
              value: o.key,
              child: Text(
                '${o.module} · ${o.item}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }

  // ---------- 免修与说明 ----------

  Widget _buildNote(ColorScheme cs) {
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '免修与课程替代',
            style: TextStyle(
              fontFamily: AppTheme.serifFontFamily,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withValues(alpha: .85),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _noteCtrl,
            maxLines: 4,
            minLines: 3,
            style: TextStyle(fontSize: 13, color: cs.onSurface),
            decoration: const InputDecoration(hintText: '记录免修、替代或学院认定的情况'),
            onChanged: (v) {
              _state.note = v;
              _persist();
            },
          ),
        ],
      ),
    );
  }

  // ---------- 小部件 ----------

  Widget _bar(ColorScheme cs, double ratio) {
    final value = ratio.isNaN ? 0.0 : ratio.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: AppShape.inner,
      child: Container(
        height: 6,
        color: AppShape.insetFill(cs),
        child: FractionallySizedBox(
          alignment: AlignmentDirectional.centerStart,
          widthFactor: value,
          child: ColoredBox(
            color: value >= 1 ? AppTheme.success : cs.primary,
            child: const SizedBox(height: 6),
          ),
        ),
      ),
    );
  }

  double _sumCredits(List<GradeCourse> courses) {
    var sum = 0.0;
    for (final c in courses) {
      sum += double.tryParse(c.xf) ?? 0;
    }
    return sum;
  }

  String _scoreLabel(GradeCourse course) {
    final score = double.tryParse(course.zcj);
    if (score == null || score <= 0) return '不计成绩';
    final name = course.zcjname1.trim();
    return name.isEmpty ? _fmt(score) : '${_fmt(score)} $name';
  }

  /// 子项学分展示：多修的部分在模块层已经封顶，这里同样只报到要求值，
  /// 否则会出现「30 / 22」这种与模块进度对不上的读数。
  String _itemLabel(ItemProgress item) {
    if (item.required <= 0) return _fmt(item.earned);
    final earned = item.earned > item.required ? item.required : item.earned;
    return '${_fmt(earned)} / ${_fmt(item.required)}';
  }

  String _fmt(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(1);
  }
}
