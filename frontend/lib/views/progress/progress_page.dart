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

  /// 体测计算器：大一到大四四个学年分的输入框，第五个是毕业成绩。
  final List<TextEditingController> _fitCtrl =
      List<TextEditingController>.generate(4, (_) => TextEditingController());
  final TextEditingController _fitResultCtrl = TextEditingController();

  /// 反推出来的空框下限提示，与 [_fitCtrl] 一一对应。
  List<String> _fitHints = List<String>.filled(4, '');

  /// 防止正反向计算互相触发。
  bool _fitSyncing = false;

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
    for (final c in _fitCtrl) {
      c.dispose();
    }
    _fitResultCtrl.dispose();
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
        // 用户重新指派了子项：这门课的人工否决（待归类 / 排除）一并撤销。
        _state.overrides[kth] = key;
        _state.unclassified.remove(kth);
        _state.excluded.remove(kth);
      }
    });
    _persist();
  }

  /// × 取消归类：把这门课从自动归好的子项里踢回「待归类课程」，等用户重新指派。
  ///
  /// 记的是 kth 级的人工否决，所以刷新成绩、重进页面后自动规则也不会再抢回去。
  void _unclassify(String kth) {
    setState(() {
      _state.overrides.remove(kth);
      _state.excluded.remove(kth);
      _state.unclassified[kth] = true;
    });
    _persist();
  }

  /// - 排除：不参与学分计算，但课程本身仍留在成绩单里，随时可以恢复。
  void _exclude(String kth) {
    setState(() {
      _state.overrides.remove(kth);
      _state.unclassified.remove(kth);
      _state.excluded[kth] = true;
    });
    _persist();
  }

  /// ↑ 恢复为待归类：从「已排除课程」退出来，回到待指派状态。
  void _backToUnmatched(String kth) {
    setState(() {
      _state.excluded.remove(kth);
      _state.unclassified[kth] = true;
    });
    _persist();
  }

  /// 勾 恢复自动归类：清掉这门课的全部人工决定，交还给自动规则。
  void _restoreAuto(String kth) {
    setState(() {
      _state.excluded.remove(kth);
      _state.unclassified.remove(kth);
      _state.overrides.remove(kth);
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
                  FeatureGate(
                    flag: FeatureGateService.flag1056ProgressBetaBadge,
                    child: const BetaBadge(fontSize: 12),
                  ),
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
              ..._buildProgressNotices(),
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
              else
                // 进度条虚线、不及格过滤等开关是直接读 service 的，
                // 这里跟着同一份 states 重建，远程切换后立刻生效。
                ValueListenableBuilder<Map<String, bool>>(
                  valueListenable: FeatureGateService.instance.states,
                  builder: (context, gateStates, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FeatureGate(
                        flag: FeatureGateService.flag1026ProgressBeta,
                        child: _buildBetaSwitch(cs),
                      ),
                      ..._buildBody(cs, major, gradesAsync),
                    ],
                  ),
                ),
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
            dropdownColor: AppShape.overlayFill(cs),
            elevation: 8,
            borderRadius: AppShape.inner,
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
      excluded: _state.excluded,
      unclassified: _state.unclassified,
    );

    return <Widget>[
      _buildOverall(cs, result),
      const SizedBox(height: AppShape.gapGroup),
      for (final module in result.modules) ...[
        _buildModule(cs, module),
        const SizedBox(height: AppShape.gapGroup),
      ],
      if (result.unmatched.isNotEmpty) ...[
        FeatureGate(
          flag: FeatureGateService.flag1097UnmatchedAssign,
          child: _buildUnmatched(cs, major, result.unmatched),
        ),
        const SizedBox(height: AppShape.gapGroup),
      ],
      if (result.excluded.isNotEmpty) ...[
        FeatureGate(
          flag: FeatureGateService.flag1097UnmatchedAssign,
          child: _buildExcluded(cs, result.excluded),
        ),
        const SizedBox(height: AppShape.gapGroup),
      ],
      FeatureGate(
        flag: FeatureGateService.flag1027Fitness,
        child: _buildFitness(cs),
      ),
      FeatureGate(
        flag: FeatureGateService.flag1028MatchRules,
        child: _buildRules(cs, major, grades),
      ),
      const SizedBox(height: AppShape.gapGroup),
      FeatureGate(
        flag: FeatureGateService.flag1098ExemptionNote,
        child: _buildNote(cs),
      ),
    ];
  }

  /// 放在页首合规提示之后，确保用户先看到使用边界与分类规则。
  List<Widget> _buildProgressNotices() {
    return const <Widget>[
      NoteBanner.warning(
        persistKey: 'progress_graduation_warning',
        title: '注意',
        text:
            '请关注劳动教育理论、劳动教育实践，职业生涯规划实践，'
            '体测四年加权成绩必须大于等于 50 分等可能造成毕业隐患的项目。',
      ),
      SizedBox(height: 16),
      NoteBanner.info(
        persistKey: 'progress_aesthetic_practice_reminder',
        title: '温馨提示',
        text:
            '1. 本程序仅根据成绩单中的课程名称、类别、学分等信息进行自动归类，不能替代学院或教务系统的正式审核\n'
            '2. 对于培养方案中存在课程范围、课程门数、类别上限、活动认定、实践要求或课程类别变更等条件的项目，程序无法仅凭成绩单自动判断是否符合要求，请您结合所在年级、专业的培养方案自行核验并按需手动调整课程归类。\n'
            '3. 您可能因个人兴趣跨专业或超额修读选修课程。这些课程可能未被计入当前项目、被标为待归类，或超过当前项目可计入的学分上限，但这并不代表该课程成绩无效，亦不代表无法计入其他项目。您可以尝试在教务系统允许的时候更改课程类别，具体以教务系统开放时间内的申请结果及所在学院的认定为准。\n'
            '4. 以美育课为例，如您已修读一门 2 学分的美育课程，通常已满足美育模块的学分要求；美育实践不应再重复计入该模块。如选择“美育理论 1 学分 + 美育实践 1 学分”的学习方式，则须分别满足两部分要求。不同年级、专业的具体规定可能不同，请以您的培养方案为准。\n'
            '5. 建议您自行着重核对美育、劳动、体育、职业生涯规划等表述差异较大或含糊不清的课程类别。',
        emphasisText: '请您手动校对每一门课程的归属，本程序不能作为认证毕业的依据，亦不对您错误使用本程序造成的任何后果承担任何责任。',
        emphasisColor: AppTheme.error,
      ),
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
                      '已修 ${_fmt(result.earned)} 分，要求修读 ${_fmt(result.required)} 分',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: cs.onSurface.withValues(alpha: .58),
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
    final count = module.items.length + 1;
    BorderRadius shapeAt(int i) =>
        AppShape.segmented(first: i == 0, last: i == count - 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < count; i++) ...[
          if (i > 0) const SizedBox(height: _segmentGap),
          _segment(
            cs,
            shape: shapeAt(i),
            // 分段的圆角要同时交给 InkWell，否则 hover 的水波纹是直角。
            child: i == 0
                ? _moduleHeader(cs, module)
                : _buildItem(cs, module.items[i - 1], shape: shapeAt(i)),
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
                '已修 ${_fmt(module.earned)} 分，要求修读 ${_fmt(module.required)} 分',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurface.withValues(alpha: .58),
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

  Widget _buildItem(ColorScheme cs, ItemProgress item, {BorderRadius? shape}) {
    final satisfied = item.satisfied;
    final expanded = _expanded.contains(item.key);
    final canExpand = item.courses.isNotEmpty;
    // 只有需要自己勾选的实践环节才铺培养方案原文，普通课程铺上去太吵。
    final requirement = item.manualCapable ? item.item.requirement : '';
    return InkWell(
      onTap: canExpand ? () => _toggleExpanded(item.key) : null,
      borderRadius: shape,
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
                // 「已修 x 分，要求修读 y 分」与进度条一起靠右对齐，
                // 所有子项在同一列上收尾；文字与条都用低饱和色，
                // 避免进度信息比课程名更抢眼。
                SizedBox(
                  width: 220,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        _itemLabel(item),
                        textAlign: TextAlign.right,
                        softWrap: true,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withValues(
                            alpha: satisfied ? .58 : .46,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      _itemBar(cs, item),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                // 可展开的放箭头；不可展开的用一条短横线占住同样宽度，
                // 这样所有子项右侧的文本与进度条都落在同一列上。
                if (canExpand)
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: cs.onSurface.withValues(alpha: .4),
                  )
                else
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: Center(
                      child: Container(
                        width: 9,
                        height: 1.5,
                        color: cs.onSurface.withValues(alpha: .16),
                      ),
                    ),
                  ),
              ],
            ),
            if (requirement.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 28, top: 3),
                child: Text(
                  requirement,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.45,
                    color: cs.onSurface.withValues(alpha: .42),
                  ),
                ),
              ),
            if (item.isSituationAndPolicy)
              Padding(
                padding: const EdgeInsets.only(left: 24, top: 4),
                child: Wrap(
                  spacing: 12,
                  children: [
                    _situationCheck(
                      '形势与政策讲座',
                      item.situationLectureKey,
                      item.situationLectureDone,
                    ),
                    _situationCheck(
                      '形势与政策研讨',
                      item.situationSeminarKey,
                      item.situationSeminarDone,
                    ),
                  ],
                ),
              ),
            if (canExpand && expanded)
              Padding(
                padding: const EdgeInsets.only(left: 24, top: 6),
                child: FeatureGate(
                  flag: FeatureGateService.flag1096ItemDetail,
                  child: _buildCourseGroups(cs, item),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _situationCheck(String label, String key, bool checked) {
    return InkWell(
      onTap: () => _toggleManual(key, !checked),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: checked,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (value) => _toggleManual(key, value ?? false),
          ),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
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
    final failed = isCourseFailed(course);
    return _HoverReveal(
      builder: (hovered) => Padding(
        // 课程名一行接一行时行距太紧会看串行，这里留出 5px 上下呼吸。
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Expanded(
              child: Text(
                course.kcname,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: cs.onSurface.withValues(alpha: .62),
                ),
              ),
            ),
            // × 取消归类 / - 排除：位置固定占宽，只做淡入淡出，
            // 鼠标扫过整行时行高与右侧成绩都不会跳。
            AnimatedOpacity(
              duration: const Duration(milliseconds: 120),
              opacity: hovered ? 1 : 0,
              child: IgnorePointer(
                ignoring: !hovered,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _SymbolAction(
                      icon: Icons.close,
                      tooltip: '取消归类',
                      onTap: () => _unclassify(course.kth),
                    ),
                    _SymbolAction(
                      icon: Icons.remove,
                      tooltip: '排除',
                      onTap: () => _exclude(course.kth),
                    ),
                  ],
                ),
              ),
            ),
            if (failed) ...[const SizedBox(width: 6), _failedTag()],
            const SizedBox(width: 10),
            Text(
              _scoreLabel(course),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: failed
                    ? AppTheme.error
                    : cs.onSurface.withValues(alpha: .55),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 不及格课程在成绩单里仍然存在，但学分不计入进度，需要一个显眼的标注。
  Widget _failedTag() {
    return FeatureGate(
      flag: FeatureGateService.flag1029FailedCourses,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: AppTheme.error.withValues(alpha: .12),
          borderRadius: AppShape.inner,
        ),
        child: Text(
          '不及格·不计学分',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: AppTheme.error,
          ),
        ),
      ),
    );
  }

  // ---------- 待归类课程 ----------

  /// 待归类课程：自动规则没认出来的，加上用户自己「取消归类」踢回来的。
  ///
  /// 每门课只有两个动作，都用符号：↑ 归入某个子项、- 排除。子项列表放在
  /// 弹层里给出「模块 · 子项」，选完就落到 overrides，优先级压过自动规则。
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
                '待归类课程',
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
                  const SizedBox(width: 6),
                  _assignMenu(cs, course.kth, options),
                  _SymbolAction(
                    icon: Icons.remove,
                    tooltip: '排除',
                    onTap: () => _exclude(course.kth),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ---------- 已排除课程 ----------

  /// 已排除课程：只是不参与学分累加，成绩单里这门课仍然在，随时可退回。
  Widget _buildExcluded(ColorScheme cs, List<GradeCourse> courses) {
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '已排除课程',
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
                  color: cs.onSurface.withValues(alpha: .06),
                  borderRadius: AppShape.inner,
                ),
                child: Text(
                  '不参与学分计算',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface.withValues(alpha: .55),
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
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: .6),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${course.xf} 学分',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: cs.onSurface.withValues(alpha: .45),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _SymbolAction(
                    icon: Icons.arrow_upward,
                    tooltip: '恢复为待归类',
                    onTap: () => _backToUnmatched(course.kth),
                  ),
                  _SymbolAction(
                    icon: Icons.check,
                    tooltip: '恢复自动归类',
                    onTap: () => _restoreAuto(course.kth),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// ↑ 归入某子项：弹层直接列全部子项，选中即落到 overrides。
  Widget _assignMenu(ColorScheme cs, String kth, List<ItemOption> options) {
    return PopupMenuButton<String>(
      tooltip: '归入某子项',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      onSelected: (key) => _setOverride(kth, key),
      itemBuilder: (context) => [
        for (final o in options)
          PopupMenuItem<String>(
            value: o.key,
            height: 36,
            child: Text(
              '${o.module} · ${o.item}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: cs.onSurface),
            ),
          ),
      ],
      // tooltip 交给外层 PopupMenuButton，避免套两层。
      child: const _SymbolAction(icon: Icons.arrow_upward),
    );
  }
  // ---------- 体测计算器 ----------

  /// 体测计算器：大一到大四四个学年分，按培养方案附录的毕业评定公式
  /// `(a+b+c)*0.5 + d*0.5 = e` 算出毕业成绩（d 为毕业当年）。
  Widget _buildFitness(ColorScheme cs) {
    const labels = <String>['大一', '大二', '大三', '大四'];
    final allFilled = _fitCtrl.every((c) => c.text.trim().isNotEmpty);
    final passed = double.tryParse(_fitResultCtrl.text.trim());
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '体测计算器',
                style: TextStyle(
                  fontFamily: AppTheme.serifFontFamily,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface.withValues(alpha: .85),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < 4; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: _fitField(
                    cs,
                    label: labels[i],
                    controller: _fitCtrl[i],
                    hint: _fitHints[i].isEmpty ? '分数' : _fitHints[i],
                    onChanged: (_) => _recalcFitness(),
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
                child: Text(
                  '=',
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface.withValues(alpha: .5),
                  ),
                ),
              ),
              Expanded(
                child: _fitField(
                  cs,
                  label: '毕业成绩',
                  controller: _fitResultCtrl,
                  hint: allFilled ? '自动' : '可反推',
                  onChanged: (_) => _recalcFitness(fromResult: true),
                ),
              ),
            ],
          ),
          if (passed != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  passed >= 50 ? Icons.check_circle : Icons.error_outline,
                  size: 14,
                  color: passed >= 50 ? AppTheme.success : AppTheme.error,
                ),
                const SizedBox(width: 6),
                Text(
                  passed >= 50
                      ? '毕业成绩 ${_fmt(passed)} 分，达到 50 分要求'
                      : '毕业成绩 ${_fmt(passed)} 分，未达到 50 分要求',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: passed >= 50 ? AppTheme.success : AppTheme.error,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 体测计算器的单个输入框。
  ///
  /// 不自建外框、也不覆盖任何尺寸参数：`TextField` 只用主题里的
  /// `inputDecorationTheme`（`AppShape.inner` 圆角、`outline` 描边、`16/14` 内边距、
  /// 聚焦时主色 2px 描边），与设置页、方案计算页的输入框同款，因此全页只有一层轮廓。
  /// 标题改成框外的灰字，避免浮动 label 在这么窄的列里被截断、把输入区顶高。
  Widget _fitField(
    ColorScheme cs, {
    required String label,
    required TextEditingController controller,
    required String hint,
    required ValueChanged<String> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11.5,
            height: 1.2,
            color: cs.onSurface.withValues(alpha: .5),
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textAlignVertical: TextAlignVertical.center,
          style: TextStyle(fontSize: 14, height: 1.2, color: cs.onSurface),
          decoration: InputDecoration(hintText: hint),
          onChanged: onChanged,
        ),
      ],
    );
  }

  /// 任一输入变化后重算：正向填 e，反向给空框算下限。
  ///
  /// 公式 `e = (a+b+c)/3 × 0.5 + d × 0.5`，等价于 `a+b+c + 1.5d = 6e`。
  /// 空框落在大一~大三时按平均分反推，落在「毕业成绩」时直接解 d。
  void _recalcFitness({bool fromResult = false}) {
    if (_fitSyncing) return;
    _fitSyncing = true;
    final hints = List<String>.filled(4, '');
    if (fromResult) {
      final target = double.tryParse(_fitResultCtrl.text.trim());
      if (target == null) {
        _fitHints = hints;
      } else {
        final blanks = <int>[];
        for (var i = 0; i < 4; i++) {
          if (double.tryParse(_fitCtrl[i].text.trim()) == null) blanks.add(i);
        }
        if (blanks.isNotEmpty) {
          // 权重：大一~大三各占 1/6，大四占 1/2。
          const weight = [1 / 6, 1 / 6, 1 / 6, 1 / 2];
          var knownWeight = 0.0;
          for (var i = 0; i < 4; i++) {
            if (blanks.contains(i)) continue;
            knownWeight +=
                (double.tryParse(_fitCtrl[i].text.trim()) ?? 0) * weight[i];
          }
          final rest = target - knownWeight;
          // 单个空框的下限：其余空框按满分 100 估，剩下的才是它必须拿到的。
          for (final i in blanks) {
            final others = blanks
                .where((j) => j != i)
                .fold<double>(0, (sum, j) => sum + weight[j] * 100);
            final need = (rest - others) / weight[i];
            hints[i] = '至少 ${_fmt(need < 0 ? 0 : need)}';
          }
        }
        _fitHints = hints;
      }
    } else {
      final values = [for (final c in _fitCtrl) double.tryParse(c.text.trim())];
      if (values.every((v) => v != null)) {
        // 毕业成绩 = 大一至大三平均分 × 50% + 大四 × 50%
        final e =
            (values[0]! + values[1]! + values[2]!) / 3 * 0.5 + values[3]! * 0.5;
        _fitResultCtrl.text = e.toStringAsFixed(1);
      } else {
        _fitResultCtrl.text = '';
      }
      _fitHints = hints;
    }
    _fitSyncing = false;
    setState(() {});
  }

  // ---------- 自定义匹配规则 ----------

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
    final rightItems = <String>[
      for (final o in options) o.key,
      ..._extraRightKeys(options),
    ];
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '自定义匹配规则',
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
          // 左框已选、右框还没选：立刻把这半条规则显示出来，
          // 不要等两边都选完才冒出来。
          if (_pendingLeft.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  Expanded(child: _ruleText(cs, _pendingLeft, height: 40)),
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
                      items: rightItems,
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
                  const SizedBox(width: 6),
                  IconButton(
                    onPressed: () => setState(() => _pendingLeft = ''),
                    icon: const Icon(Icons.close, size: 16),
                    tooltip: '取消',
                  ),
                ],
              ),
            )
          else
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
                      hint: '先选左侧',
                      value: null,
                      items: rightItems,
                      labelOf: (key) => _optionLabel(options, key),
                      onChanged: null,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 右框还允许直接选已经存在的自定义目标，避免用户被迫重新输入。
  List<String> _extraRightKeys(List<ItemOption> options) {
    final known = {for (final o in options) o.key};
    final extra = <String>{};
    for (final rule in _state.rules) {
      if (!known.contains(rule.right)) extra.add(rule.right);
    }
    return extra.toList()..sort();
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

  Widget _ruleText(ColorScheme cs, String text, {double height = 36}) {
    return Container(
      height: height,
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
    required ValueChanged<String?>? onChanged,
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
            color: cs.onSurface.withValues(alpha: onChanged == null ? .3 : .45),
          ),
        ),
        style: _dropdownStyle(cs),
        dropdownColor: AppShape.overlayFill(cs),
        elevation: 8,
        borderRadius: AppShape.inner,
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

  /// 总进度条 / 模块进度条。
  ///
  /// 结构：已完成胶囊 + 固定间隙 + 未完成胶囊。两段完全分离，间隙固定
  /// 不随进度变化，右端就是轨道本身的圆角收尾。
  ///
  /// 必须显式给 `width: double.infinity`：`CustomPaint` 没有 child 时自身宽度
  /// 是 `Size.zero`，放进 `crossAxisAlignment.start` 的 Column 会被压成 0 宽，
  /// 看上去就像进度条消失了。
  Widget _bar(ColorScheme cs, double ratio, {double height = 6}) {
    final value = ratio.isNaN ? 0.0 : ratio.clamp(0.0, 1.0);
    return SizedBox(
      width: double.infinity,
      height: height,
      child: CustomPaint(
        painter: _PillBarPainter(
          // 总/模块进度条也压一档饱和度，避免整页被高亮主色刷满。
          ratio: value,
          fill: value >= 1
              ? AppTheme.success.withValues(alpha: .78)
              : cs.primary.withValues(alpha: .82),
          showRest: _restEnabled,
        ),
      ),
    );
  }

  /// 子项级小进度条：220 宽、4 高，紧跟在「已修 x 分，要求修读 y 分」下方，
  /// 右端与所有子项在同一列收尾；比总进度条细一档，不抢注意力。
  Widget _itemBar(ColorScheme cs, ItemProgress item) {
    final value = item.ratio.isNaN ? 0.0 : item.ratio.clamp(0.0, 1.0);
    // 低饱和：完成用柔和的绿，未完成用主色降透明度，避免子项比标题更亮。
    final fill = item.satisfied
        ? AppTheme.success.withValues(alpha: .62)
        : cs.primary.withValues(alpha: .55);
    return SizedBox(
      width: 220,
      height: 4,
      child: CustomPaint(
        painter: _PillBarPainter(
          ratio: value,
          fill: fill,
          showRest: _restEnabled,
        ),
      ),
    );
  }

  /// Flag-1099：是否绘制未完成段（低透明度主色）。关闭后只留已完成段。
  bool get _restEnabled =>
      FeatureGateService.instance.isEnabled(FeatureGateService.flag1099DashBar);

  double _sumCredits(List<GradeCourse> courses) {
    var sum = 0.0;
    for (final c in courses) {
      sum += courseCredits(c);
    }
    return sum;
  }

  /// 成绩展示：`97分，4.0`（加权分数 + 单课绩点）。
  ///
  /// 绩点只能由 `jd / xf` 得出——`zcjname1` 在数字成绩时与 `zcj` 相同，
  /// 直接拼会得到「88 88」这种重复读数。两级制课程按等级原样显示。
  String _scoreLabel(GradeCourse course) {
    final grade = course.zcjname1.trim();
    if (grade == 'P' || grade == 'F' || grade == '通过' || grade == '不通过') {
      return grade;
    }
    final score = double.tryParse(course.zcj);
    if (score == null || score <= 0) return '不计成绩';
    final gpa = _courseGpa(course);
    return gpa == null ? '${_fmt(score)}分' : '${_fmt(score)}分，$gpa';
  }

  /// 单课绩点 = jd / xf，保留一位小数。
  String? _courseGpa(GradeCourse course) {
    final jd = double.tryParse(course.jd);
    final xf = double.tryParse(course.xf);
    if (jd == null || xf == null || xf == 0) return null;
    return (jd / xf).toStringAsFixed(1);
  }

  /// 子项学分展示：超额课程要明确保留，避免把兴趣多修或待改类课程误说成
  /// 「没有修过」。但模块进度仍只按本项上限计算。
  String _itemLabel(ItemProgress item) {
    if (item.required <= 0) return '已修 ${_fmt(item.earned)} 分';
    if (item.excessCredits > 0) {
      return '当前实际修读${_fmt(item.earned)}分，要求修读${_fmt(item.required)}分，超出了${_fmt(item.excessCredits)}分。';
    }
    return '已修 ${_fmt(item.countedCredits)} 分，要求修读 ${_fmt(item.required)} 分';
  }

  String _fmt(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(1);
  }
}

/// 进度条画笔：Material 3 Expressive 胶囊样式。
///
/// 两个元素：已完成胶囊、未完成胶囊。两段之间留固定间隙，圆角半径恒为高度
/// 的一半，整条轨道铺满可用宽度。不画渐变、描边或阴影。
class _PillBarPainter extends CustomPainter {
  const _PillBarPainter({
    required this.ratio,
    required this.fill,
    this.showRest = true,
  });

  final double ratio;
  final Color fill;

  /// Flag-1099：未完成段是否绘制。
  final bool showRest;

  /// 两段之间的固定间隙，按高度的 0.6 倍取，保证任何进度下间距一致。
  static const double _gapFactor = .6;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    if (h <= 0 || size.width <= 0) return;
    final value = ratio.isNaN ? 0.0 : ratio.clamp(0.0, 1.0);
    final r = h / 2;

    // 轨道铺满整个宽度，两段之间保留一个按高度换算的固定间隙。
    final gap = h * _gapFactor;
    final usable = (size.width - gap).clamp(0.0, size.width);

    // 满进度：未完成段消失，已完成段铺满整条轨道，
    // 不在末端留下一小截孤立圆角；间隙只在有未完成段时出现。
    final full = value >= 1;
    final doneW = full ? size.width : usable * value;
    final restW = full ? 0.0 : usable - doneW;

    // 已完成段：值为 0 时不画，避免留下一个圆角小疙瘩。
    if (doneW > .5) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, doneW, h),
          Radius.circular(doneW < h ? doneW / 2 : r),
        ),
        Paint()..color = fill,
      );
    }

    // 未完成段：同一主色的低透明度版本，满进度时不画。
    if (showRest && restW > .5) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(doneW + gap, 0, restW, h),
          Radius.circular(restW < h ? restW / 2 : r),
        ),
        Paint()..color = fill.withValues(alpha: .16),
      );
    }
  }

  @override
  bool shouldRepaint(_PillBarPainter old) =>
      old.ratio != ratio || old.fill != fill || old.showRest != showRest;
}

/// 鼠标进入时才把 hover 状态传给子树的包装：用于「课程行 hover 出动作」。
///
/// 只负责转发 hover，不加背景、不占额外空间，行高保持原样。
class _HoverReveal extends StatefulWidget {
  const _HoverReveal({required this.builder});

  final Widget Function(bool hovered) builder;

  @override
  State<_HoverReveal> createState() => _HoverRevealState();
}

class _HoverRevealState extends State<_HoverReveal> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: widget.builder(_hovered),
    );
  }
}

/// 归类动作按钮：界面上只出符号（↑ × - 勾），含义全部收进 tooltip。
///
/// 尺寸固定 22×22、符号 14，保证一排按钮基线一致、行高不跳。
class _SymbolAction extends StatefulWidget {
  const _SymbolAction({required this.icon, this.tooltip, this.onTap});

  final IconData icon;

  /// 为空时不再套一层 Tooltip（外层 PopupMenuButton 已经带了一个）。
  final String? tooltip;

  /// 为空时只作视觉占位（点击由外层 PopupMenuButton 之类的父节点接管）。
  final VoidCallback? onTap;

  @override
  State<_SymbolAction> createState() => _SymbolActionState();
}

class _SymbolActionState extends State<_SymbolAction> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final body = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: _hovered
                ? cs.onSurface.withValues(alpha: .08)
                : Colors.transparent,
            borderRadius: AppShape.inner,
          ),
          child: Icon(
            widget.icon,
            size: 14,
            color: cs.onSurface.withValues(alpha: _hovered ? .82 : .5),
          ),
        ),
      ),
    );
    final tip = widget.tooltip;
    if (tip == null) return body;
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 600),
      child: body,
    );
  }
}
