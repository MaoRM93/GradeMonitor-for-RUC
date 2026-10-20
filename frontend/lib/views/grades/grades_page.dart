import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/grades_provider.dart';
import '../../providers/settings_provider.dart';

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
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: '搜索课程名称...',
                        prefixIcon: const Icon(Icons.search_rounded, size: 20),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear_rounded, size: 18),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                },
                              )
                            : null,
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
                      DropdownButton<String>(
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
                    ],
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
                  final filtered = _searchQuery.isEmpty
                      ? bySemester
                      : bySemester
                            .where(
                              (g) => g.kcname.toLowerCase().contains(
                                _searchQuery.toLowerCase(),
                              ),
                            )
                            .toList();

                  if (filtered.isEmpty) {
                    final emptyText = _searchQuery.isNotEmpty
                        ? '无匹配结果'
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
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
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
                          fontSize: 13,
                          color: colorScheme.onSurface,
                        ),
                        columnSpacing: 16,
                        horizontalMargin: 12,
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
