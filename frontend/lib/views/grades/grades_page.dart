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
      for (final c in courses) {
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
          credits: credits,
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
              padding: const EdgeInsets.fromLTRB(28, 44, 28, 6),
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
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '查看您的全部成绩，您可以点击表头分别排序每一项指标',
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.onSurface.withValues(alpha: .5),
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
                    child: TextField(
                      controller: _searchController,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '搜索课程名称...',
                        hintStyle: const TextStyle(fontSize: 12),
                        prefixIcon: const Icon(Icons.search_rounded, size: 18),
                        prefixIconConstraints: const BoxConstraints(
                          minWidth: 34,
                          minHeight: 34,
                        ),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.clear_rounded, size: 18),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                },
                              )
                            : null,
                        suffixIconConstraints: const BoxConstraints(
                          minWidth: 34,
                          minHeight: 34,
                        ),
                      ),
                      onChanged: (v) => setState(() => _searchQuery = v),
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
                      final widths = _adaptiveWidths(
                        constraints.maxWidth - 28 * 2 - 2,
                      );
                      return Container(
                        margin: const EdgeInsets.fromLTRB(28, 4, 28, 14),
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: colorScheme.onSurface.withValues(alpha: .25),
                          ),
                        ),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 表头（固定，不随数据滚动）
                              DataTable(
                                sortColumnIndex: _sortColumnIndex,
                                sortAscending: _sortAscending,
                                headingRowColor: WidgetStateProperty.all(
                                  colorScheme.surfaceContainerHighest
                                      .withValues(alpha: .5),
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

  /// 表头列：显式列宽，与数据表共用同一组列宽配置
  /// 学期统计卡片：每个学期一行，显示门数 / 学分 / GPA
  Widget _buildSemesterStats(
    ColorScheme colorScheme,
    List<_SemesterStat> stats,
  ) {
    // 汇总行：全部学期的合计
    final totalCount = stats.fold<int>(0, (a, s) => a + s.count);
    final totalCredits = stats.fold<double>(0, (a, s) => a + s.credits);
    final totalJd = stats.fold<double>(
      0,
      (a, s) => a + (s.gpa ?? 0) * s.credits,
    );
    final totalGpa = totalCredits > 0 ? totalJd / totalCredits : null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 0, 28, 10),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: colorScheme.onSurface.withValues(alpha: .18),
          ),
          color: colorScheme.surfaceContainerHighest.withValues(alpha: .28),
        ),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.insights_rounded,
                  size: 16,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  '按学期统计',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'GPA = Σ学分绩点 ÷ Σ学分',
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSurface.withValues(alpha: .45),
                  ),
                ),
                const Spacer(),
                Text(
                  '合计 $totalCount 门 · ${totalCredits.toStringAsFixed(1)} 学分 · '
                  'GPA ${totalGpa == null ? '-' : totalGpa.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 学期较多时自动换行（不引入横向滚动条，避免末尾卡片被截断）
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in stats)
                  Container(
                    padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: colorScheme.surface,
                      border: Border.all(
                        color: colorScheme.onSurface.withValues(alpha: .12),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          s.term,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _statChip(
                              colorScheme,
                              '${s.count} 门',
                              Icons.menu_book_rounded,
                            ),
                            const SizedBox(width: 8),
                            _statChip(
                              colorScheme,
                              '${s.credits.toStringAsFixed(1)} 学分',
                              Icons.school_rounded,
                            ),
                            const SizedBox(width: 8),
                            _statChip(
                              colorScheme,
                              'GPA ${s.gpa == null ? '-' : s.gpa!.toStringAsFixed(2)}',
                              null,
                              emphasize: true,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
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

  /// DataTable 的固定开销：列间距 8 × 7 + 左右外边距 8 × 2
  static const double _tableChrome = 8 * 7 + 8 * 2;

  /// 按可用宽度自适应列宽：
  /// - 窗口足够宽时，把多出来的空间全部给「课程名称」列，使表格铺满整行
  ///   （与上方警告条、学期统计卡的左右边界对齐）；
  /// - 窗口过窄时退回固有宽度，由外层横向滚动兜底，不会挤压数字列。
  ///
  /// 表头表与数据表必须使用同一组宽度，否则两表列会错位。
  List<double> _adaptiveWidths(double availableWidth) {
    final natural =
        _naturalWidths.fold<double>(0, (a, b) => a + b) + _tableChrome;
    final target = availableWidth > natural ? availableWidth : natural;
    final extra = target - natural;
    final widths = List<double>.from(_naturalWidths);
    if (extra > 0) widths[1] += extra; // 多出的空间给课程名称列
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
            child: SizedBox(
              width: 200,
              child: Text(
                course.kcname,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
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

  /// 该学期课程门数（含无学分/无绩点的课程）
  final int count;

  /// 参与 GPA 计算的课程数（有学分且有学分绩点）
  final int countedCourses;

  /// 学分合计
  final double credits;

  /// 学期 GPA = Σ学分绩点 ÷ Σ学分；无有效课程时为 null
  final double? gpa;

  const _SemesterStat({
    required this.term,
    required this.count,
    required this.countedCourses,
    required this.credits,
    required this.gpa,
  });
}
