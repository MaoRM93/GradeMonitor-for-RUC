import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grademonitor/core/network/api_client.dart';
import 'package:grademonitor/core/theme/app_theme.dart';
import 'package:grademonitor/providers/grades_provider.dart';
import 'package:grademonitor/views/grades/grades_page.dart';

class _FakeGrades extends GradesNotifier {
  _FakeGrades(List<GradeCourse> list) : super(ApiClient()) {
    state = AsyncValue.data(list);
  }
  @override
  Future<void> fetchGrades() async {}
}

List<GradeCourse> _loadGrades() {
  final raw = File('test/fixtures/grades_52.json').readAsStringSync();
  return (jsonDecode(raw) as List)
      .map((e) => GradeCourse.fromJson(e as Map<String, dynamic>))
      .toList();
}

Future<void> _pumpPage(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        gradesProvider.overrideWith((ref) => _FakeGrades(_loadGrades())),
      ],
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        home: const Scaffold(body: GradesPage()),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 200));
}

Rect _rectOf(Element e) {
  final box = e.renderObject! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

void main() {
  testWidgets('表格铺满内容区、与统计卡对齐、无横向滚动', (tester) async {
    await _pumpPage(tester, const Size(1440, 900));

    final tables = find
        .byType(DataTable)
        .evaluate()
        .map(_rectOf)
        .toList();
    expect(tables.length, 2, reason: '表头表 + 数据表');
    // 两表列宽必须一致，否则表头与数据列错位
    expect(tables[0].width, closeTo(tables[1].width, 0.01));

    final statsCard = _rectOf(
      find
          .byWidgetPredicate(
            (w) =>
                w is Container &&
                w.padding is EdgeInsets &&
                (w.padding! as EdgeInsets).left == 14,
          )
          .evaluate()
          .first,
    );

    // 表格容器有 1px 边框，故表格比统计卡左右各内缩 1px 即为精确对齐
    expect(tables[0].left, closeTo(statsCard.left + 1, 1.01));
    expect(tables[0].right, closeTo(statsCard.right - 1, 1.01));
    // 铺满：表格宽度应等于内容区宽度 − 左右外边距 − 边框
    expect(tables[0].width, closeTo(1440 - 28 * 2 - 2, 1.01));

    // 正常窗口下不应出现横向滚动
    final hScroll = find
        .byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.right,
        )
        .evaluate();
    for (final e in hScroll) {
      final st = (e as StatefulElement).state as ScrollableState;
      expect(
        st.position.maxScrollExtent,
        closeTo(0, 0.01),
        reason: '正常窗口宽度下不应有横向滚动条',
      );
    }
  });

  for (final w in [1100.0, 1280.0, 1600.0, 1920.0, 2560.0]) {
    testWidgets('窗口宽 ${w.toInt()} 时表格精确铺满且与统计卡对齐', (tester) async {
      await _pumpPage(tester, Size(w, 900));
      final tables = find.byType(DataTable).evaluate().map(_rectOf).toList();
      expect(tables.length, 2);
      expect(tables[0].width, closeTo(tables[1].width, 0.01));
      final statsCard = _rectOf(
        find
            .byWidgetPredicate(
              (x) =>
                  x is Container &&
                  x.padding is EdgeInsets &&
                  (x.padding! as EdgeInsets).left == 14,
            )
            .evaluate()
            .first,
      );
      expect(tables[0].left, closeTo(statsCard.left + 1, 1.01));
      expect(tables[0].right, closeTo(statsCard.right - 1, 1.01));
      expect(tables[0].width, closeTo(w - 28 * 2 - 2, 1.01));
    });
  }

  testWidgets('按学期统计排除 PF 制课程（合计 52 门 / 91.0 学分 / GPA 3.74）', (
    tester,
  ) async {
    await _pumpPage(tester, const Size(1440, 900));
    // 合计行：门数按全部课程计，学分与 GPA 只计非 PF 课程
    expect(find.textContaining('合计 52 门'), findsOneWidget);
    expect(find.textContaining('91.0 学分'), findsOneWidget);
    expect(find.textContaining('GPA 3.74'), findsOneWidget);
    expect(find.textContaining('PF 6 门'), findsOneWidget);
    // 各学期口径（与教务 sumxf/pjxfjd 一致）
    expect(find.text('14 门'), findsOneWidget);
    expect(find.text('26.0 学分'), findsOneWidget);
    expect(find.text('GPA 3.78'), findsOneWidget);
    expect(find.text('GPA 3.49'), findsOneWidget); // 2024-2025 秋，含 3 门 PF
    expect(find.text('GPA 3.70'), findsOneWidget); // 国际小学期
  });

  testWidgets('窄窗口下退回最小列宽并由横向滚动兜底', (tester) async {
    await _pumpPage(tester, const Size(760, 900));
    final tables = find.byType(DataTable).evaluate().map(_rectOf).toList();
    expect(tables.length, 2);
    expect(tables[0].width, closeTo(tables[1].width, 0.01));
    // 列宽被压到下限后仍超宽，此时允许横向滚动
    expect(tables[0].width, greaterThan(760 - 28 * 2 - 2 - 1));
  });
}
