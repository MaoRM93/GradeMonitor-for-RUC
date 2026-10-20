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
      for (final g in gradesList) if (g.xnxq.isNotEmpty) g.xnxq,
    };
    final semesterItems = <String>[
      '全部',
      ...semesterSet.toList()..sort((a, b) => b.compareTo(a)),
    ];
    final semesterValue = semesterItems.contains(_semester)
        ? _semester
        : '全部';

    // 核心绩口径：白名单 ∩ 有效课程（与下方核心绩筛选所见课程集合一致）
    final coreResult = gradesList.isEmpty
        ? null
        : CoreGpaUtil.analyze(gradesList);
    final coreCount = coreResult?.courses.length ?? 0;
    final coreText = coreResult?.gpaText ?? '-';

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
                    message: '核心绩＝核心绩课程白名单（按 kclbname 全字匹配）的'
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
                              (g) => (coreResult?.courses ?? const <GradeCourse>[]).contains(
                                g,
                              ),
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

                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
                      child: Container(
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: colorScheme.onSurface.withValues(alpha: .25),
                          ),
                        ),
                        child: DataTable(
                        sortColumnIndex: _sortColumnIndex,
                        sortAscending: _sortAscending,
                        headingRowColor: WidgetStateProperty.all(
                          colorScheme.surfaceContainerHighest.withValues(
                            alpha: .5,
                          ),
                        ),
                        headingTextStyle: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: colorScheme.onSurface,
                        ),
                        dataTextStyle: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurface,
                        ),
                        columnSpacing: 8,
                        horizontalMargin: 8,
                        // 表头居中：DataTable 会在标签左侧补排序箭头等宽占位，
                        // 使"学期↑"这类带排序箭头的表头与数据列对中一致
                        columns: [
                          DataColumn(label: const Center(child: Text('学期')), headingRowAlignment: MainAxisAlignment.center, onSort: (i, asc) => setState(() { _sortColumnIndex = i; _sortAscending = asc; })),
                          DataColumn(label: const Center(child: Text('课程名称')), headingRowAlignment: MainAxisAlignment.center, onSort: (i, asc) => setState(() { _sortColumnIndex = i; _sortAscending = asc; })),
                          DataColumn(label: const Center(child: Text('学分')), numeric: true, headingRowAlignment: MainAxisAlignment.center, onSort: (i, asc) => setState(() { _sortColumnIndex = i; _sortAscending = asc; })),
                          DataColumn(label: const Center(child: Text('平时成绩')), numeric: true, headingRowAlignment: MainAxisAlignment.center, onSort: (i, asc) => setState(() { _sortColumnIndex = i; _sortAscending = asc; })),
                          DataColumn(label: const Center(child: Text('期末成绩')), numeric: true, headingRowAlignment: MainAxisAlignment.center, onSort: (i, asc) => setState(() { _sortColumnIndex = i; _sortAscending = asc; })),
                          DataColumn(label: const Center(child: Text('加权成绩')), numeric: true, headingRowAlignment: MainAxisAlignment.center, onSort: (i, asc) => setState(() { _sortColumnIndex = i; _sortAscending = asc; })),
                          DataColumn(label: const Center(child: Text('绩点')), numeric: true, headingRowAlignment: MainAxisAlignment.center, onSort: (i, asc) => setState(() { _sortColumnIndex = i; _sortAscending = asc; })),
                          DataColumn(label: const Center(child: Text('平均学分绩点')), numeric: true, headingRowAlignment: MainAxisAlignment.center, onSort: (i, asc) => setState(() { _sortColumnIndex = i; _sortAscending = asc; })),
                        ],
                        rows: sorted
                            .map(
                              (course) => DataRow(
                                cells: [
                                  DataCell(
                                    Center(
                                      child: Text(
                                        course.xnxq.isEmpty ? '-' : course.xnxq,
                                      ),
                                    ),
                                  ),
                                  DataCell(
                                    Center(
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 200,
                                        ),
                                        child: Text(
                                          course.kcname,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                  ),
                                  DataCell(
                                    Center(
                                      child: Text(
                                        course.xf.isEmpty ? '-' : course.xf,
                                      ),
                                    ),
                                  ),
                                  DataCell(
                                    Center(
                                      child: Text(
                                        course.cjxm1.isEmpty
                                            ? '-'
                                            : course.cjxm1,
                                      ),
                                    ),
                                  ),
                                  DataCell(
                                    Center(
                                      child: Text(
                                        course.cjxm3.isEmpty
                                            ? '-'
                                            : course.cjxm3,
                                      ),
                                    ),
                                  ),
                                  DataCell(
                                    Center(
                                      child: Text(
                                        course.zcj.isEmpty ? '-' : course.zcj,
                                      ),
                                    ),
                                  ),
                                  DataCell(
                                    Center(
                                      child: Text(
                                        course.jd.isEmpty ? '-' : course.jd,
                                      ),
                                    ),
                                  ),
                                  DataCell(
                                    Center(
                                      child: Text(
                                        course.avgGpa,
                                        style: _gpaStyle(
                                          course.avgGpa,
                                          colorScheme,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            )
                            .toList(),
                        ),
                      ),
                    ),
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
