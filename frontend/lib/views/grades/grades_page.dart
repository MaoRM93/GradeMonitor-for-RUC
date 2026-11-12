import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/grades_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/note_banner.dart';
import '../scheme/scheme_core.dart';

class GradesPage extends ConsumerStatefulWidget {
  const GradesPage({super.key});
  @override
  ConsumerState<GradesPage> createState() => _GradesPageState();
}

class _GradesPageState extends ConsumerState<GradesPage> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  String _semester = '全部';
  int _sortColumnIndex = 0;
  bool _sortAscending = true;

  /// 范围筛选：false = 全部课程；true = 核心绩课程（白名单∩有效成绩）
  bool _scopeCore = false;

  /// 按学期汇总统计（门数 / 学分 / GPA）
  ///
  /// GPA 口径与表内「绩点」列一致：`jd` 是学分绩点（绩点×学分），
  /// 因此学期 GPA = Σjd ÷ Σxf，与 `GradeCourse.avgGpa` 的单课口径同源。
  ///
  /// **PF 制（两级制）课程不参与 GPA 计算**：既不计入分子 Σjd，
  /// 也不计入分母 Σxf（与教务系统 `sumxf`/`pjxfjd` 口径一致）。
  /// 门数仍按该学期全部课程统计（与下方表格所见门数一致）。
  List<_SemesterStat> _semesterStats(List<GradeCourse> list) {
    final grouped = <String, List<GradeCourse>>{};
    for (final g in list) {
      if (g.xnxq.isEmpty) continue;
      grouped.putIfAbsent(g.xnxq, () => []).add(g);
    }
    final stats = <_SemesterStat>[];
    grouped.forEach((term, courses) {
      var credits = 0.0;
      var jdSum = 0.0;
      var counted = 0;
      var passFail = 0;
      for (final c in courses) {
        // PF 制课程（P/F、合格/不合格…）整体剔除，不参与 GPA 与学分合计
        if (CoreGpaUtil.isPassFail(c)) {
          passFail++;
          continue;
        }
        final xf = double.tryParse(c.xf);
        final jd = double.tryParse(c.jd);
        if (xf == null || xf <= 0 || jd == null) continue;
        credits += xf;
        jdSum += jd;
        counted++;
      }
      stats.add(
        _SemesterStat(
          term: term,
          count: courses.length,
          countedCourses: counted,
          passFailCourses: passFail,
          credits: credits,
          jdSum: jdSum,
          gpa: credits > 0 ? jdSum / credits : null,
        ),
      );
    });
    // 学期降序（新在前）
    stats.sort((a, b) => b.term.compareTo(a.term));
    return stats;
  }

  int _numCmp(String a, String b) {
    final na = double.tryParse(a) ?? 0;
    final nb = double.tryParse(b) ?? 0;
    return na.compareTo(nb);
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(gradesProvider.notifier).fetchGrades());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gradesAsync = ref.watch(gradesProvider);
    final settings = ref.watch(settingsProvider);
    final hideUnknown = settings.hideUnknownCourses;
    final colorScheme = Theme.of(context).colorScheme;
    // 与搜索框 OutlineInputBorder 同源的边框色（跟随主题亮暗）
    final borderColor = Theme.of(context).brightness == Brightness.dark
        ? AppTheme.darkBorder
        : AppTheme.lightBorder;

    // 学期筛选选项：来自全部成绩数据的学期集合（降序）
    final gradesList = gradesAsync.asData?.value ?? const <GradeCourse>[];
    final semesterSet = <String>{
      for (final g in gradesList)
        if (g.xnxq.isNotEmpty) g.xnxq,
    };
    final semesterItems = <String>[
      '全部',
      ...semesterSet.toList()..sort((a, b) => b.compareTo(a)),
    ];
    final semesterValue = semesterItems.contains(_semester) ? _semester : '全部';

    // 核心绩口径：白名单 ∩ 有效课程（与下方核心绩筛选所见课程集合一致）
    final coreResult = gradesList.isEmpty
        ? null
        : CoreGpaUtil.analyze(gradesList);
    final coreCount = coreResult?.courses.length ?? 0;
    final coreText = coreResult?.gpaText ?? '-';

    // 按学期统计（已应用「隐藏未知课程」口径，与表格所见一致）
    final statSource = hideUnknown
        ? gradesList.where((g) => g.kcname != '未知课程').toList()
        : gradesList;
    final semesterStats = _semesterStats(statSource);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 44, 28, 14),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '成绩单',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 12),
              child: NoteBanner.warning(
                persistKey: 'grades_core_gpa',
                title: '注意',
                text:
                    '由于学校培养方案持续更新，不同年级、专业的课程类别与培养要求可能存在差异，'
                    '且培养方案中的课程分类与教务系统实际记录的字段可能不完全对应，'
                    '因此本功能的核心绩筛选及平均学分绩点计算结果可能存在一定误差，仅供参考。'
                    '请以学校及学院发布的正式文件和教务系统核算结果为准，'
                    '并自行核验相关课程的纳入范围及计算结果。',
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 8),
              child: Row(
                children: [
                  Expanded(
                    // 搜索框与右侧「学期 / 范围」下拉框同高同圆角（4 / 圆角 4），
                    // 样式直接覆盖主题里的大圆角填充框，保持一行对齐。
                    child: SizedBox(
                      height: 34,
                      child: TextField(
                        controller: _searchController,
                        style: const TextStyle(fontSize: 13),
                        textAlignVertical: TextAlignVertical.center,
                        decoration: InputDecoration(
                          isDense: true,
                          filled: true,
                          fillColor: colorScheme.surface,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          hintText: '搜索课程名称...',
                          hintStyle: const TextStyle(fontSize: 12),
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            size: 16,
                          ),
                          prefixIconConstraints: const BoxConstraints(
                            minWidth: 30,
                            minHeight: 30,
                          ),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  icon: const Icon(
                                    Icons.clear_rounded,
                                    size: 16,
                                  ),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() => _searchQuery = '');
                                  },
                                )
                              : null,
                          suffixIconConstraints: const BoxConstraints(
                            minWidth: 30,
                            minHeight: 30,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(4),
                            borderSide: BorderSide(color: borderColor),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(4),
                            borderSide: BorderSide(color: borderColor),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(4),
                            borderSide: BorderSide(
                              color: colorScheme.primary,
                              width: 1.2,
                            ),
                          ),
                        ),
                        onChanged: (v) => setState(() => _searchQuery = v),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '学期：',
                        style: TextStyle(
                          fontSize: 13,
                          color: colorScheme.onSurface.withValues(alpha: .6),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(color: borderColor),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: DropdownButton<String>(
                          value: semesterValue,
                          items: semesterItems
                              .map(
                                (s) => DropdownMenuItem(
                                  value: s,
                                  child: Text(
                                    s,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (v) =>
                              setState(() => _semester = v ?? '全部'),
                          underline: const SizedBox(),
                          isDense: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '范围：',
                        style: TextStyle(
                          fontSize: 13,
                          color: colorScheme.onSurface.withValues(alpha: .6),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(color: borderColor),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: DropdownButton<String>(
                          value: _scopeCore ? 'core' : 'all',
                          items: const [
                            DropdownMenuItem(
                              value: 'all',
                              child: Text(
                                '全部课程',
                                style: TextStyle(fontSize: 13),
                              ),
                            ),
                            DropdownMenuItem(
                              value: 'core',
                              child: Text(
                                '核心绩课程',
                                style: TextStyle(fontSize: 13),
                              ),
                            ),
                          ],
                          onChanged: (v) =>
                              setState(() => _scopeCore = v == 'core'),
                          underline: const SizedBox(),
                          isDense: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Tooltip(
                    message:
                        '核心绩＝核心绩课程白名单（按 kclbname 全字匹配）的'
                        '学分加权平均绩点（Σ绩点÷Σ学分）。'
                        '统计课程集合与「核心绩课程」筛选所见完全一致。',
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.verified_rounded,
                          size: 15,
                          color: colorScheme.primary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '核心绩',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurface.withValues(alpha: .6),
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          coreText,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '$coreCount/${gradesList.length} 门',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: colorScheme.onSurface.withValues(alpha: .55),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (semesterStats.isNotEmpty)
              _buildSemesterStats(colorScheme, semesterStats),
            Expanded(
              child: gradesAsync.when(
                data: (grades) {
                  var list = hideUnknown
                      ? grades.where((g) => g.kcname != '未知课程').toList()
                      : grades;
                  final bySemester = _semester == '全部'
                      ? list
                      : list.where((g) => g.xnxq == _semester).toList();
                  // 核心绩筛选：白名单 ∩ 有效课程（与统计口径同一集合）
                  final inScope = _scopeCore
                      ? bySemester
                            .where(
                              (g) =>
                                  (coreResult?.courses ?? const <GradeCourse>[])
                                      .contains(g),
                            )
                            .toList()
                      : bySemester;
                  final filtered = _searchQuery.isEmpty
                      ? inScope
                      : inScope
                            .where(
                              (g) => g.kcname.toLowerCase().contains(
                                _searchQuery.toLowerCase(),
                              ),
                            )
                            .toList();

                  if (filtered.isEmpty) {
                    final emptyText = _searchQuery.isNotEmpty
                        ? '无匹配结果'
                        : _scopeCore
                        ? '核心绩课程在当前筛选下暂无有效成绩'
                        : _semester != '全部'
                        ? '该学期暂无成绩数据'
                        : '暂无成绩数据';
                    return Center(
                      child: Text(
                        emptyText,
                        style: TextStyle(
                          color: colorScheme.onSurface.withValues(alpha: .35),
                          fontSize: 14,
                        ),
                      ),
                    );
                  }

                  final sorted = List<GradeCourse>.from(filtered);
                  sorted.sort((a, b) {
                    int cmp;
                    switch (_sortColumnIndex) {
                      case 0:
                        cmp = a.xnxq.compareTo(b.xnxq);
                        break;
                      case 1:
                        cmp = a.kcname.compareTo(b.kcname);
                        break;
                      case 2:
                        cmp = _numCmp(a.xf, b.xf);
                        break;
                      case 3:
                        cmp = _numCmp(a.cjxm1, b.cjxm1);
                        break;
                      case 4:
                        cmp = _numCmp(a.cjxm3, b.cjxm3);
                        break;
                      case 5:
                        cmp = _numCmp(a.zcj, b.zcj);
                        break;
                      case 6:
                        cmp = _numCmp(a.jd, b.jd);
                        break;
                      case 7:
                        cmp = _numCmp(a.avgGpa, b.avgGpa);
                        break;
                      default:
                        cmp = 0;
                    }
                    return _sortAscending ? cmp : -cmp;
                  });

                  // 冻结表头：表头表固定，数据表单独垂直滚动（表头不随滚动移动）；
                  // 两表共用同一组列宽（按可用宽度自适应），保证表头与数据列对齐。
                  // 外边距 28 与上方警告条、学期统计卡一致，随窗口宽度自适应。
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      // 可用宽度 = 内容区宽度 − 左右各 28 的外边距，与上方警告条、
                      // 学期统计卡（均为 Padding 28）完全一致。
                      // 再减去容器边框 1px×2：BoxDecoration 的 border 会 inset 子节点，
                      // 表格实际可用宽度比容器外框窄 2px，不减会让表格溢出 2px 并出现
                      // 一条无意义的横向滚动条。
                      // 列宽总和 + 表格自身留白(_tableChrome) 恰好等于该宽度，
                      // 从而表格与上方卡片左右严格对齐。
                      final available = constraints.maxWidth - 28 * 2 - 2;
                      final widths = _adaptiveWidths(available);
                      final tableWidth =
                          widths.fold<double>(0, (a, b) => a + b) +
                          _tableChrome;
                      // 正常窗口下 tableWidth == available（精确铺满）；窗口过窄时
                      // tableWidth > available，由外层横向滚动兜底。
                      final contentWidth = tableWidth < available
                          ? available
                          : tableWidth;
                      return Container(
                        margin: const EdgeInsets.fromLTRB(28, 4, 28, 14),
                        clipBehavior: Clip.antiAlias,
                        // 表格底色：浅色模式为纯白（cs.surface 即 0xFFFFFFFF），
                        // 深色模式自动跟随主题深色 surface，无需写死白色。
                        decoration: BoxDecoration(
                          color: colorScheme.surface,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: contentWidth,
                            // DataTable 本体不自带底色，用 ColoredBox 铺满 surface：
                            // 浅色下即纯白，深色下为深色 surface，跟随主题。
                            child: ColoredBox(
                              color: colorScheme.surface,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // 表头（固定，不随数据滚动）
                                  DataTable(
                                    sortColumnIndex: _sortColumnIndex,
                                    sortAscending: _sortAscending,
                                    // 表头底色比数据区更深一档（主色淡淡叠在灰底上）
                                    headingRowColor: WidgetStateProperty.all(
                                      Color.alphaBlend(
                                        colorScheme.primary.withValues(
                                          alpha: .12,
                                        ),
                                        colorScheme.surfaceContainerHighest,
                                      ),
                                    ),
                                    headingTextStyle: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: colorScheme.onSurface,
                                    ),
                                    columnSpacing: 8,
                                    horizontalMargin: 8,
                                    columns: _headColumnsFor(widths),
                                    rows: const [],
                                  ),
                                  // 数据区（仅该区域垂直滚动，表头恒定在上方）
                                  Expanded(
                                    child: SingleChildScrollView(
                                      child: DataTable(
                                        headingRowHeight: 0,
                                        dataRowColor: WidgetStatePropertyAll(
                                          colorScheme.surface,
                                        ),
                                        dataTextStyle: TextStyle(
                                          fontSize: 12,
                                          color: colorScheme.onSurface,
                                        ),
                                        columnSpacing: 8,
                                        horizontalMargin: 8,
                                        columns: _bodyColumnsFor(widths),
                                        rows: sorted
                                            .map(
                                              (course) =>
                                                  _dataRow(course, colorScheme),
                                            )
                                            .toList(),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, _) => Center(
                  child: Text(
                    '加载成绩失败',
                    style: TextStyle(color: colorScheme.error, fontSize: 14),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 成绩表：冻结表头（表头表 + 数据表共用列宽） ----------

  void _handleSort(int i, bool asc) {
    setState(() {
      _sortColumnIndex = i;
      _sortAscending = asc;
    });
  }

  /// 学期统计卡片：每个学期一张等宽卡片，显示门数 / 学分 / GPA
  ///
  /// 只呈现各学期结果，不再显示算法说明、合计概览与 PF 门数；
  /// 数据口径仍完全来自 [_semesterStats]（PF 制课程不计入学分与 GPA）。
  Widget _buildSemesterStats(
    ColorScheme colorScheme,
    List<_SemesterStat> stats,
  ) {
    return Padding(
      // 左右边距 28 与下方成绩表格完全一致，卡片行左右边界与表格对齐
      padding: const EdgeInsets.fromLTRB(28, 0, 28, 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 每行放几张：卡片最小宽度 150，其余按可用宽度均分，
          // 从而每行都铺满 28…宽度-28，且同一行卡片尺寸一致。
          const gap = 8.0;
          const minCardWidth = 150.0;
          final available = constraints.maxWidth;
          var perRow =
              ((available + gap) / (minCardWidth + gap)).floor().clamp(1, 8);
          if (perRow > stats.length) perRow = stats.length;
          if (perRow < 1) perRow = 1;
          final cardWidth = (available - gap * (perRow - 1)) / perRow;
          final rows = <Widget>[];
          for (var i = 0; i < stats.length; i += perRow) {
            final chunk = stats.sublist(
              i,
              (i + perRow) > stats.length ? stats.length : i + perRow,
            );
            rows.add(
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 0 : gap),
                child: Row(
                  children: [
                    for (var j = 0; j < chunk.length; j++) ...[
                      if (j > 0) const SizedBox(width: gap),
                      SizedBox(
                        width: cardWidth,
                        height: 80,
                        child: _semesterCard(colorScheme, chunk[j]),
                      ),
                    ],
                  ],
                ),
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: rows,
          );
        },
      ),
    );
  }

  Widget _semesterCard(ColorScheme colorScheme, _SemesterStat s) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: colorScheme.surface,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            s.term,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          // 卡片宽度固定：容纳不下时等比缩小，避免溢出
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _statChip(colorScheme, '${s.count} 门', Icons.menu_book_rounded),
                const SizedBox(width: 8),
                _statChip(
                  colorScheme,
                  '${s.credits.toStringAsFixed(1)} 学分',
                  Icons.school_rounded,
                ),
              ],
            ),
          ),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: _statChip(
              colorScheme,
              'GPA ${s.gpa == null ? '-' : s.gpa!.toStringAsFixed(2)}',
              null,
              emphasize: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statChip(
    ColorScheme colorScheme,
    String text,
    IconData? icon, {
    bool emphasize = false,
  }) {
    final color = emphasize
        ? colorScheme.primary
        : colorScheme.onSurface.withValues(alpha: .6);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
        ],
        Text(
          text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: emphasize ? FontWeight.w700 : FontWeight.w500,
            color: color,
          ),
        ),
      ],
    );
  }

  DataColumn _headCol(
    String label, {
    TableColumnWidth? width,
    bool numeric = false,
  }) {
    return DataColumn(
      label: Center(child: Text(label)),
      numeric: numeric,
      headingRowAlignment: MainAxisAlignment.center,
      columnWidth: width,
      onSort: _handleSort,
    );
  }

  /// 各列固有宽度（表头 label + 排序箭头 + 内边距计算所得）
  static const List<double> _naturalWidths = [
    150, // 学期
    200, // 课程名称
    72, // 学分
    96, // 平时成绩
    96, // 期末成绩
    96, // 加权成绩
    72, // 绩点
    124, // 平均学分绩点
  ];

  /// 各列最小宽度。
  ///
  /// 除「课程名称」外，其余列的固有宽度就是其**内容不可再压缩的下限**（表头文字
  /// 含排序箭头 + 单元格内边距）。低于该值 Flutter 会抛 RenderFlex overflow
  /// （界面出现黄黑警示条），因此压缩只允许发生在「课程名称」这一列；
  /// 窗口再窄则退回本组宽度，由外层横向滚动兜底。
  static const List<double> _minWidths = [
    150, // 学期
    120, // 课程名称（唯一可压缩列）
    72, // 学分
    96, // 平时成绩
    96, // 期末成绩
    96, // 加权成绩
    72, // 绩点
    124, // 平均学分绩点
  ];

  /// DataTable 的额外开销。
  ///
  /// 注意：`columnSpacing` / `horizontalMargin` 只决定单元格**内边距**，而内边距
  /// 是画在 `FixedColumnWidth` 的列宽**内部**的（见 flutter/lib/src/material/
  /// data_table.dart 的 `_buildDataCell`：padding 由 cell 自己消费）。
  /// 因此表格的总宽度 == Σ列宽，不需要再额外加间距与外边距——否则表格会比
  /// 上方统计卡窄掉 72px，这正是"表格宽度没修好"的真实原因。
  static const double _tableChrome = 0;

  /// 按可用宽度自适应列宽，保证表格**始终精确铺满**可用宽度：
  /// - 空间富余：多出来的宽度全部给「课程名称」列；
  /// - 空间不足：先把「课程名称」压到最小，再按各列可压缩比例等比压缩其余列；
  /// - 极端窄窗口（连最小宽度都放不下）：退回最小宽度，由外层横向滚动兜底。
  ///
  /// 表头表与数据表必须使用同一组宽度，否则两表列会错位。
  List<double> _adaptiveWidths(double availableWidth) {
    final target = availableWidth - _tableChrome;
    final natural = _naturalWidths.fold<double>(0, (a, b) => a + b);
    final minSum = _minWidths.fold<double>(0, (a, b) => a + b);
    final widths = List<double>.from(_naturalWidths);

    if (target >= natural) {
      // 富余：全部给课程名称列
      widths[1] += target - natural;
      return widths;
    }
    if (target <= minSum) {
      // 过窄：退回最小宽度，外层横向滚动
      return List<double>.from(_minWidths);
    }

    // 压缩：先压课程名称，再按可压缩比例压其余列
    var deficit = natural - target;
    final courseShrink = (widths[1] - _minWidths[1]).clamp(0.0, deficit);
    widths[1] -= courseShrink;
    deficit -= courseShrink;
    if (deficit > 0) {
      const flexible = [0, 2, 3, 4, 5, 6, 7];
      final spare = flexible.fold<double>(
        0,
        (a, i) => a + (widths[i] - _minWidths[i]),
      );
      if (spare > 0) {
        final ratio = deficit / spare;
        for (final i in flexible) {
          widths[i] -= (widths[i] - _minWidths[i]) * ratio;
        }
      }
    }
    return widths;
  }

  List<DataColumn> _headColumnsFor(List<double> widths) => [
    _headCol('学期', width: FixedColumnWidth(widths[0])),
    _headCol('课程名称', width: FixedColumnWidth(widths[1])),
    _headCol('学分', width: FixedColumnWidth(widths[2]), numeric: true),
    _headCol('平时成绩', width: FixedColumnWidth(widths[3]), numeric: true),
    _headCol('期末成绩', width: FixedColumnWidth(widths[4]), numeric: true),
    _headCol('加权成绩', width: FixedColumnWidth(widths[5]), numeric: true),
    _headCol('绩点', width: FixedColumnWidth(widths[6]), numeric: true),
    _headCol('平均学分绩点', width: FixedColumnWidth(widths[7]), numeric: true),
  ];

  /// 数据表列：隐形表头（空 label、不可排序、0 高），仅用于与表头共用列宽
  List<DataColumn> _bodyColumnsFor(List<double> widths) => [
    for (final w in widths)
      DataColumn(
        label: const SizedBox.shrink(),
        columnWidth: FixedColumnWidth(w),
      ),
  ];

  /// 学期文本：在「学年」后插入换行，两行居中显示（如 2024-2025学年 / 春季学期）
  String _termText(String xnxq) {
    if (xnxq.isEmpty) return '-';
    final i = xnxq.indexOf('学年');
    if (i < 0) return xnxq;
    final rest = xnxq.substring(i + 2);
    return rest.isEmpty ? xnxq : '${xnxq.substring(0, i + 2)}\n$rest';
  }

  DataRow _dataRow(GradeCourse course, ColorScheme cs) {
    return DataRow(
      cells: [
        DataCell(
          Center(
            child: Text(_termText(course.xnxq), textAlign: TextAlign.center),
          ),
        ),
        DataCell(
          Center(
            child: Text(
              course.kcname,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        DataCell(Center(child: Text(course.xf.isEmpty ? '-' : course.xf))),
        DataCell(
          Center(child: Text(course.cjxm1.isEmpty ? '-' : course.cjxm1)),
        ),
        DataCell(
          Center(child: Text(course.cjxm3.isEmpty ? '-' : course.cjxm3)),
        ),
        DataCell(Center(child: Text(course.zcj.isEmpty ? '-' : course.zcj))),
        DataCell(Center(child: Text(course.jd.isEmpty ? '-' : course.jd))),
        DataCell(
          Center(
            child: Text(course.avgGpa, style: _gpaStyle(course.avgGpa, cs)),
          ),
        ),
      ],
    );
  }

  TextStyle _gpaStyle(String gpa, ColorScheme cs) {
    final v = double.tryParse(gpa);
    Color c = cs.onSurface;
    if (v != null) {
      if (v >= 4.0) {
        c = const Color(0xFF10B981);
      } else if (v >= 3.3) {
        c = const Color(0xFF3B82F6);
      } else if (v >= 2.0) {
        c = const Color(0xFFF59E0B);
      } else {
        c = const Color(0xFFEF4444);
      }
    }
    return TextStyle(fontWeight: FontWeight.w700, color: c);
  }
}

/// 单个学期的汇总统计
class _SemesterStat {
  /// 学期名（如「2025-2026学年秋季学期」）
  final String term;

  /// 该学期课程门数（含 PF 制、无学分/无绩点的课程）
  final int count;

  /// 参与 GPA 计算的课程数（有学分且有学分绩点，且不是 PF 制）
  final int countedCourses;

  /// 参与 GPA 计算的学分合计（不含 PF 制课程）
  final double credits;

  /// 参与 GPA 计算的学分绩点合计（不含 PF 制课程）
  final double jdSum;

  /// 该学期 PF 制（通过/不通过）课程门数，不计入 GPA
  final int passFailCourses;

  /// 学期 GPA = Σ学分绩点 ÷ Σ学分；无有效课程时为 null
  final double? gpa;

  const _SemesterStat({
    required this.term,
    required this.count,
    required this.countedCourses,
    required this.credits,
    required this.jdSum,
    required this.passFailCourses,
    required this.gpa,
  });
}
