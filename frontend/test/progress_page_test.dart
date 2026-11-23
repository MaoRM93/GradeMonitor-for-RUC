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

  test('人工排除的课程不参与计算，但仍留在成绩单里', () {
    final plan = _plan();
    final grades = _grades();
    final major = _major(plan, '2024', '马克思主义理论');
    final base = computeProgress(
      major: major,
      grades: grades,
      overrides: const <String, String>{},
      manual: const <String, bool>{},
    );
    final core = base.modules
        .expand((m) => m.items)
        .firstWhere((i) => i.item.name == '专业核心课');
    final target = core.courses.first;
    final after = computeProgress(
      major: major,
      grades: grades,
      overrides: const <String, String>{},
      manual: const <String, bool>{},
      excluded: <String, bool>{target.kth: true},
    );
    // 排除只影响累加：这门课不再进任何子项，单独落进 excluded。
    expect(after.assigned.containsKey(target.kth), isFalse);
    expect(after.excluded.map((c) => c.kth), contains(target.kth));
    expect(
      after.allItems.fold<int>(0, (sum, i) => sum + i.courses.length) +
          after.unmatched.length +
          after.excluded.length,
      grades.length,
    );
    expect(after.earned, lessThan(base.earned));
  });

  test('取消归类的课程回到待归类，自动规则不再抢回去', () {
    final plan = _plan();
    final grades = _grades();
    final major = _major(plan, '2024', '马克思主义理论');
    final base = computeProgress(
      major: major,
      grades: grades,
      overrides: const <String, String>{},
      manual: const <String, bool>{},
    );
    final core = base.modules
        .expand((m) => m.items)
        .firstWhere((i) => i.item.name == '专业核心课');
    final target = core.courses.first;
    final after = computeProgress(
      major: major,
      grades: grades,
      overrides: const <String, String>{},
      manual: const <String, bool>{},
      unclassified: <String, bool>{target.kth: true},
    );
    expect(after.assigned.containsKey(target.kth), isFalse);
    expect(after.unmatched.map((c) => c.kth), contains(target.kth));
    // 排除与取消归类都是人工决定，压过 overrides。
    final override = computeProgress(
      major: major,
      grades: grades,
      overrides: <String, String>{target.kth: '专业模块/专业核心课'},
      manual: const <String, bool>{},
      unclassified: <String, bool>{target.kth: true},
    );
    expect(override.unmatched.map((c) => c.kth), contains(target.kth));
  });

  test('排除与取消归类随进度状态一起持久化', () {
    final state = ProgressState(
      overrides: <String, String>{'1': '专业模块/专业核心课'},
      manual: <String, bool>{'专业模块/专业实习': true},
      excluded: <String, bool>{'2': true},
      unclassified: <String, bool>{'3': true},
      note: '备注',
    );
    final restored = ProgressState.fromJson(
      jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>,
    );
    expect(restored.excluded, <String, bool>{'2': true});
    expect(restored.unclassified, <String, bool>{'3': true});
    expect(restored.overrides, state.overrides);
    expect(restored.note, '备注');
    // 旧版本存档里没有这两个字段时必须安全退化为空表。
    final legacy = ProgressState.fromJson(<String, dynamic>{
      'overrides': <String, String>{},
      'manual': <String, bool>{},
      'rules': <dynamic>[],
      'note': '',
    });
    expect(legacy.excluded, isEmpty);
    expect(legacy.unclassified, isEmpty);
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

  test('形势与政策从思政理论课拆出，由讲座和研讨共同确认 2 学分', () {
    final major = _major(_plan(), '2024', '马克思主义理论');
    final base = computeProgress(
      major: major,
      grades: const <GradeCourse>[],
      overrides: const <String, String>{},
      manual: const <String, bool>{},
    );
    final checked = computeProgress(
      major: major,
      grades: const <GradeCourse>[],
      overrides: const <String, String>{},
      manual: const <String, bool>{
        '通识模块/形势与政策/形势与政策讲座': true,
        '通识模块/形势与政策/形势与政策研讨': true,
      },
    );
    final category = checked.allItems.firstWhere(
      (item) => item.item.name == '形势与政策',
    );
    final thoughtTheory = checked.allItems.firstWhere(
      (item) => item.item.name == '思想政治理论课',
    );
    expect(category.satisfied, isTrue);
    expect(category.earned, 2);
    expect(thoughtTheory.required, 0);
    expect(checked.earned - base.earned, 2);
  });

  test('思政实践课只默认归类到非马理论专业的思想政治理论课', () {
    const practice = GradeCourse(
      kth: 'practice',
      kcname: '思政实践课',
      xf: '2',
      kclbname: '思想政治理论课',
      zcj: '61',
      zcjname1: 'P',
    );
    final plan = _plan();
    final marxism = computeProgress(
      major: _major(plan, '2024', '马克思主义理论'),
      grades: const <GradeCourse>[practice],
      overrides: const <String, String>{},
      manual: const <String, bool>{},
    );
    final philosophy = computeProgress(
      major: _major(plan, '2024', '哲学'),
      grades: const <GradeCourse>[practice],
      overrides: const <String, String>{},
      manual: const <String, bool>{},
    );
    expect(marxism.unmatched.map((course) => course.kth), contains('practice'));
    expect(philosophy.assigned['practice'], '通识模块/思想政治理论课');
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

  test('不及格课程不计学分，重修通过后覆盖旧记录', () {
    const failed = GradeCourse(
      kth: '1',
      kcname: '高等数学',
      xf: '3',
      zcj: '52',
      zcjname1: '52',
    );
    const failGrade = GradeCourse(
      kth: '2',
      kcname: '大学物理',
      xf: '2',
      zcj: '40',
      zcjname1: 'F',
    );
    const passed = GradeCourse(
      kth: '3',
      kcname: '高等数学',
      xf: '3',
      zcj: '81',
      zcjname1: '81',
    );
    // P/F 课通过时学校给的 zcj 是 61，不能当成不及格。
    const pf = GradeCourse(
      kth: '4',
      kcname: '新生研讨课',
      xf: '1',
      zcj: '61',
      zcjname1: 'P',
    );

    expect(isCourseFailed(failed), isTrue);
    expect(isCourseFailed(failGrade), isTrue);
    expect(isCourseFailed(passed), isFalse);
    expect(isCourseFailed(pf), isFalse);
    expect(courseCredits(failed), 0);
    expect(courseCredits(passed), 3);

    // 高等数学挂了一次又修过：旧记录被覆盖，只留通过的那条。
    final kept = dropCoveredFailures(<GradeCourse>[failed, failGrade, passed]);
    expect(kept.length, 2);
    expect(kept.any((c) => c.kth == '1'), isFalse);
    expect(kept.any((c) => c.kth == '2'), isTrue);
  });

  test('不及格课程不会让模块进度虚高', () {
    final plan = _plan();
    final major = _major(plan, '2024', '马克思主义理论');
    const good = GradeCourse(
      kth: '1',
      kcname: '思想道德与法治',
      xf: '3',
      kclbname: '思想政治理论课',
      zcj: '90',
      zcjname1: '90',
    );
    const bad = GradeCourse(
      kth: '2',
      kcname: '中国近现代史纲要',
      xf: '3',
      kclbname: '思想政治理论课',
      zcj: '45',
      zcjname1: '45',
    );
    final result = computeProgress(
      major: major,
      grades: const <GradeCourse>[good, bad],
      overrides: const <String, String>{},
      manual: const <String, bool>{},
    );
    final item = result.allItems.firstWhere((i) => i.item.name == '思想政治理论课');
    expect(item.courses.length, 2);
    // 两门各 3 学分，挂掉的那门只算 0。
    expect(item.earned, 3);
  });

  test('超额归类课程保留实际学分，但模块只计到子项上限', () {
    final plan = _plan();
    final major = _major(plan, '2025', '马克思主义理论');
    const first = GradeCourse(
      kth: 'beauty-1',
      kcname: '美育课程甲',
      xf: '2',
      kclbname: '美育课程',
      zcj: '80',
      zcjname1: '80',
    );
    const second = GradeCourse(
      kth: 'beauty-2',
      kcname: '美育实践',
      xf: '1',
      kclbname: '美育课程',
      zcj: '61',
      zcjname1: 'P',
    );
    final result = computeProgress(
      major: major,
      grades: const <GradeCourse>[first, second],
      overrides: const <String, String>{},
      manual: const <String, bool>{},
    );
    final beauty = result.allItems.firstWhere(
      (item) => item.item.name == '美育课程',
    );
    expect(beauty.earned, 3);
    expect(beauty.countedCredits, 2);
    expect(beauty.excessCredits, 1);
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
    // 待归类分组必须出现在页面上，供用户手工归类。
    expect(find.text('待归类课程'), findsOneWidget);
  });
}
