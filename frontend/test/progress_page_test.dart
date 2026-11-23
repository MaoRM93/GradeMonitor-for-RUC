import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grademonitor/core/network/api_client.dart';
import 'package:grademonitor/core/service/ui_prefs_service.dart';
import 'package:grademonitor/core/theme/app_theme.dart';
import 'package:grademonitor/providers/grades_provider.dart';
import 'package:grademonitor/providers/settings_provider.dart';
import 'package:grademonitor/views/progress/progress_core.dart';
import 'package:grademonitor/views/progress/progress_page.dart';
import 'package:grademonitor/views/progress/progress_store.dart';

class _FakeGrades extends GradesNotifier {
  _FakeGrades(List<GradeCourse> list) : super(ApiClient()) {
    state = AsyncValue.data(list);
  }
  @override
  Future<void> fetchGrades() async {}
}

class _FakeSettings extends SettingsNotifier {
  _FakeSettings() : super(ApiClient()) {
    state = const AppSettings(username: '2024200000');
  }
}

List<GradeCourse> _grades() {
  final raw = File('test/fixtures/grades_52.json').readAsStringSync();
  return (jsonDecode(raw) as List)
      .map((e) => GradeCourse.fromJson(e as Map<String, dynamic>))
      .toList();
}

CurriculumPlan _plan() {
  final raw = File('assets/curricula/curriculum_plan.json').readAsStringSync();
  return CurriculumPlan.fromJson(jsonDecode(raw));
}

PlanMajor _major(CurriculumPlan plan, String year, String name) =>
    plan.years[year]!.firstWhere((m) => m.name == name);

void main() {
  setUpAll(() {
    // 偏好落盘改到临时文件：测试不许污染真实用户的 ui_prefs.json。
    final dir = Directory.systemTemp.createTempSync('gm_progress_test');
    UiPrefsService.debugFilePath = '${dir.path}/ui_prefs.json';
  });

  test('培养方案数据覆盖三个年级且专业齐全', () {
    final plan = _plan();
    expect(plan.gradeList, containsAll(<String>['2024', '2025', '2026']));
    for (final year in plan.gradeList) {
      expect(plan.years[year]!.length, greaterThan(50));
      for (final major in plan.years[year]!) {
        expect(major.total, greaterThan(0));
      }
    }
  });

  test('马理论三届总学分与模块学分正确', () {
    final plan = _plan();
    expect(_major(plan, '2024', '马克思主义理论').total, 140);
    expect(_major(plan, '2025', '马克思主义理论').total, 126);
    expect(_major(plan, '2026', '马克思主义理论').total, 126);
    final modules2025 = _major(plan, '2025', '马克思主义理论').modules;
    expect(modules2025.map((m) => m.name), contains('立本模块'));
    expect(modules2025.map((m) => m.name), contains('卓越模块'));
  });

  test('同名类别自动归类，异名类别一律进未归类', () {
    final plan = _plan();
    final grades = _grades();
    final result = computeProgress(
      major: _major(plan, '2024', '马克思主义理论'),
      grades: grades,
      overrides: const <String, String>{},
      manual: const <String, bool>{},
    );
    // 默认策略是「全字匹配，宁可漏判不可错判」：成绩单里的类别名与培养方案
    // 子项名不同名时不得猜，必须留在未归类里等用户确认或开高级分类。
    expect(result.earned, greaterThan(50));
    final core = result.modules
        .expand((m) => m.items)
        .firstWhere((i) => i.item.name == '专业核心课');
    expect(core.courses.length, greaterThan(10));
    // 落位 + 未归类必须等于成绩单总数，一门课不能既算进又待归类。
    final placed = result.allItems.fold<int>(
      0,
      (sum, item) => sum + item.courses.length,
    );
    expect(placed + result.unmatched.length, grades.length);
    // 未归类的只能是通识侧那些方案里没有同名子项的类别。
    const looseCategories = <String>{
      '科研与实践环节',
      '新生研讨课',
      '心理健康教育',
      '美育课程',
      '暑期学校',
      '通识核心课',
    };
    for (final course in result.unmatched) {
      expect(
        looseCategories,
        contains(course.kclbname),
        reason: '${course.kcname} 的类别 ${course.kclbname} 不该落空',
      );
    }
  });

  test('用户指定类别优先于自动匹配', () {
    final plan = _plan();
    final grades = _grades();
    final first = grades.first;
    final result = computeProgress(
      major: _major(plan, '2024', '马克思主义理论'),
      grades: grades,
      overrides: <String, String>{first.kth: '专业模块/专业核心课'},
      manual: const <String, bool>{},
    );
    expect(result.assigned[first.kth], '专业模块/专业核心课');
  });

  test('实践项勾选后计为已完成', () {
    final plan = _plan();
    final major = _major(plan, '2024', '马克思主义理论');
    final before = computeProgress(
      major: major,
      grades: const <GradeCourse>[],
      overrides: const <String, String>{},
      manual: const <String, bool>{},
    );
    final after = computeProgress(
      major: major,
      grades: const <GradeCourse>[],
      overrides: const <String, String>{},
      manual: <String, bool>{'创新训练与科学研究/专业实习': true},
    );
    expect(after.earned - before.earned, 4);
  });

  test('三届全部专业都能算出进度且不抛异常', () {
    final plan = _plan();
    final grades = _grades();
    var count = 0;
    for (final year in plan.gradeList) {
      final majors = plan.years[year]!;
      expect(majors, isNotEmpty, reason: '$year 没有专业');
      for (final major in majors) {
        final result = computeProgress(
          major: major,
          grades: grades,
          overrides: const <String, String>{},
          manual: const <String, bool>{},
        );
        expect(result.required, greaterThan(0), reason: '$year ${major.name}');
        expect(result.ratio.isNaN, isFalse, reason: '$year ${major.name}');
        // 同一门课只能落进一个子项，不能既计入又算待归类。
        final placed = result.allItems.fold<int>(
          0,
          (sum, item) => sum + item.courses.length,
        );
        expect(
          placed + result.unmatched.length,
          grades.length,
          reason: '$year ${major.name}',
        );
        count++;
      }
    }
    expect(count, greaterThan(200));
  });

  testWidgets('未选专业时不出进度数据，只提示先选专业', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => CurriculumPlan.load());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gradesProvider.overrideWith((ref) => _FakeGrades(_grades())),
          settingsProvider.overrideWith((ref) => _FakeSettings()),
        ],
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          home: const Scaffold(body: ProgressPage()),
        ),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('修读进度'), findsOneWidget);
    expect(find.text('先选择专业，再查看修读进度'), findsOneWidget);
    expect(find.text('通识模块'), findsNothing);
    // 大标题下的红色提示不允许关闭：既没有叉，也没有「不再显示」。
    expect(find.text('不再显示'), findsNothing);
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('修读进度页可渲染并显示专业与模块', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // 预热资源缓存：rootBundle 读盘在测试环境不会随 pump 推进，
    // 先走真实异步把 JSON 读进来，页面首帧就能直接命中缓存。
    await tester.runAsync(() async {
      await CurriculumPlan.load();
      // 页面刻意不替用户挑专业，这里模拟「上次已选过马理论」。
      await ProgressStore.saveMajor('2024', '马克思主义理论');
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gradesProvider.overrideWith((ref) => _FakeGrades(_grades())),
          settingsProvider.overrideWith((ref) => _FakeSettings()),
        ],
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          home: const Scaffold(body: ProgressPage()),
        ),
      ),
    );
    // 页面首帧在加载资源，CircularProgressIndicator 是无限动画，
    // 用 pumpAndSettle 会一直等下去，这里按固定节拍推进到数据就位。
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('修读进度'), findsOneWidget);
    expect(find.text('马克思主义理论'), findsWidgets);
    expect(find.text('通识模块'), findsWidgets);
    expect(find.text('专业模块'), findsWidgets);
    // 未归类分组必须出现在页面上，供用户手工归类。
    expect(find.text('未归类课程'), findsOneWidget);
  });
}
