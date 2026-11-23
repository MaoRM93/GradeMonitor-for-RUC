import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../../core/service/feature_gate_service.dart';
import '../../providers/grades_provider.dart';
import 'progress_store.dart';

/// 培养方案修读要求的结构化数据（由 scripts/build_curriculum_plan.py 离线生成）。
///
/// 运行时不解析 PDF：后端与前端都不引入 PDF 依赖，这里只读构建产物
/// `assets/curricula/curriculum_plan.json`。
class PlanItem {
  const PlanItem({required this.name, required this.credits, this.note = ''});

  final String name;
  final double credits;

  /// 培养方案里这一项的修读要求原文（离线抽取时截断到 200 字）。
  /// 实践类子项（研究训练、专业实习、毕业论文…）靠这段文字说明怎么算完成。
  final String note;

  /// 只有确实写了要求的才值得显示：`必修`、`国际性学习课程〔4〕` 这类只是标注，
  /// 当要求展示反而占地方。
  String get requirement {
    var text = note.trim();
    if (text.isEmpty) return '';
    // 方案原文用「▲」做条目符号、用「〔N〕」标注第 N 类/第 N 学期，都不是要求本身。
    text = text.replaceAll('▲', '').trim();
    final stripped = text.replaceAll(RegExp(r'〔[^〕]*〕'), '').trim();
    if (stripped.isEmpty) return '';
    if (stripped == name) return '';
    if (stripped == '必修' || stripped == '选修') return '';
    // 「选修2学分课程」这类短标注也只说明修读性质，真正的修读要求都更长。
    if (stripped.length <= 10 &&
        (stripped.startsWith('必修') || stripped.startsWith('选修'))) {
      return '';
    }
    return text;
  }
}

class PlanModule {
  const PlanModule({
    required this.name,
    required this.credits,
    required this.items,
    this.countsTowardOverall = true,
  });

  final String name;
  final double credits;
  final List<PlanItem> items;

  /// 仅用于单独核验、不会重复计入培养方案总学分的门类。
  final bool countsTowardOverall;
}

class PlanMajor {
  const PlanMajor({
    required this.name,
    required this.total,
    required this.modules,
  });

  final String name;
  final double total;
  final List<PlanModule> modules;
}

class CurriculumPlan {
  const CurriculumPlan(this.years);

  /// 年级 -> 该年级全部专业
  final Map<String, List<PlanMajor>> years;

  static CurriculumPlan? _cache;

  static Future<CurriculumPlan> load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final raw = await rootBundle.loadString(
      'assets/curricula/curriculum_plan.json',
    );
    final plan = CurriculumPlan.fromJson(jsonDecode(raw));
    _cache = plan;
    return plan;
  }

  /// 从构建产物还原；测试可直接喂文件内容，不必走 rootBundle。
  static CurriculumPlan fromJson(Object? decoded) {
    final years = <String, List<PlanMajor>>{};
    if (decoded is Map && decoded['years'] is Map) {
      for (final entry in (decoded['years'] as Map).entries) {
        final majors = <PlanMajor>[];
        final list = entry.value is Map ? (entry.value as Map)['majors'] : null;
        if (list is List) {
          for (final m in list) {
            if (m is! Map) continue;
            final modules = <PlanModule>[];
            final rawModules = m['modules'];
            if (rawModules is List) {
              for (final mod in rawModules) {
                if (mod is! Map) continue;
                final items = <PlanItem>[];
                final rawItems = mod['items'];
                if (rawItems is List) {
                  for (final it in rawItems) {
                    if (it is! Map) continue;
                    items.add(
                      PlanItem(
                        name: (it['name'] ?? '').toString(),
                        credits: _toDouble(it['credits']),
                        note: (it['note'] ?? '').toString(),
                      ),
                    );
                  }
                }
                modules.add(
                  PlanModule(
                    name: (mod['name'] ?? '').toString(),
                    credits: _toDouble(mod['credits']),
                    items: items,
                  ),
                );
              }
            }
            majors.add(
              PlanMajor(
                name: (m['name'] ?? '').toString(),
                total: _toDouble(m['total']),
                modules: modules,
              ),
            );
          }
        }
        years[entry.key.toString()] = majors;
      }
    }
    return CurriculumPlan(years);
  }

  List<String> get gradeList {
    final keys = years.keys.toList()..sort();
    return keys;
  }
}

double _toDouble(Object? raw) {
  if (raw is num) return raw.toDouble();
  return double.tryParse('${raw ?? ''}') ?? 0;
}

/// 类别名的字面归一：只抹平**同一个词的不同写法**，不做同义猜测。
///
/// 允许的差异只有三种（用户明确认可"少一个课字不要紧"）：
///   1. 全角/半角括号、多余空白；
///   2. 末尾的括注，如「公共外语（拓展类课程）」→「公共外语」；
///   3. 末尾的「课」字，如「公共外语课」→「公共外语」。
///
/// 语义不同的名字（「数据与信息技术平台课」vs「人工智能与数据技术平台课」、
/// 「科研与实践环节」vs「军事课」）一律**不**等价：宁可漏判进「未归类」，
/// 也不要把课程塞进错误的子项，错配比漏配更难被发现。
String normalizeCategory(String raw) {
  var s = raw.replaceAll('\u3000', ' ').replaceAll(RegExp(r'\s+'), '');
  s = s.replaceAll('(', '（').replaceAll(')', '）');
  final open = s.indexOf('（');
  if (open > 0) s = s.substring(0, open);
  while (s.endsWith('课') && s.length > 2) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// 只能靠用户申报完成、成绩单里没有对应课程的子项。
///
/// 名单按三个年级的方案取并集：2024 用「毕业论文 / 专业实践活动 / 职业生涯规划」，
/// 2025、2026 用「毕业论文（设计）/ 国际性学习课程 / 专业特色创新训练 / 创新引导课」，
/// 另有少数专业独有的一次性子项（学年论文、科研实践训练…）也一并列出，
/// 否则它们在页面上既匹配不到课程、也没有勾选入口。
const Set<String> kManualItems = <String>{
  '研究训练',
  '专业实习',
  '毕业论文',
  '毕业论文（设计）',
  '专业实践活动',
  '其他专业实践活动',
  '学年论文',
  '科研实践训练',
  '创新研究与科研训练',
  '“卓越三农”综合训练',
  '能力训练与素质拓展',
  '专业特色创新训练',
  '专业特色创新训练（创研进阶课）',
  '专业特色创新训练（创研课）',
  '国际性学习课程',
  '创新引导课',
  '志愿服务',
  '劳动教育',
  '马克思主义经典著作研读营',
};

String itemKey(String module, String item) => '$module/$item';

bool _isIdeologicalTheoryItem(String name) {
  final normalized = normalizeCategory(name);
  return normalized == '思想政治理论' || normalized == '思政';
}

/// 将形势与政策从原有思政理论课的 2 学分中单列，仍属于同一培养方案模块。
List<PlanModule> progressModules(PlanMajor major) {
  var added = false;
  final modules = <PlanModule>[];
  for (final module in major.modules) {
    final items = <PlanItem>[];
    for (final item in module.items) {
      if (!added && _isIdeologicalTheoryItem(item.name)) {
        items.add(
          PlanItem(
            name: item.name,
            credits: item.credits >= 2 ? item.credits - 2 : 0,
            note: item.note,
          ),
        );
        items.add(const PlanItem(name: '形势与政策', credits: 2));
        added = true;
      } else {
        items.add(item);
      }
    }
    modules.add(
      PlanModule(
        name: module.name,
        credits: module.credits,
        countsTowardOverall: module.countsTowardOverall,
        items: items,
      ),
    );
  }
  return modules;
}

/// 培养方案里的一个子项在界面上的选项（自定义组合右侧下拉用）。
class ItemOption {
  const ItemOption({
    required this.key,
    required this.module,
    required this.item,
  });

  final String key;
  final String module;
  final String item;
}

List<ItemOption> itemOptions(PlanMajor major) {
  final out = <ItemOption>[];
  for (final module in major.modules) {
    for (final item in module.items) {
      out.add(
        ItemOption(
          key: itemKey(module.name, item.name),
          module: module.name,
          item: item.name,
        ),
      );
    }
  }
  return out;
}

/// 子项里一门课在展开区的分组标签。
///
/// - 没有分数（P/F、只记通过）的课单独成「自选（不计成绩）」组，对应
///   培养方案里"会出现在成绩单但不计入绩点"的自选学分；
/// - 体育类固定按必修/选修拆，因为体育的要求就是这两种叠加；
/// - 打开「高级分类[Beta]」时，其余子项按成绩单原始类别名再细拆一层
///   （通识课程群 → 新生研讨课 / 心理健康教育 / 美育课程 …）。
String courseGroupLabel(GradeCourse course, String itemName, bool beta) {
  final score = double.tryParse(course.zcj);
  if (score == null || score <= 0) return '自选（不计成绩）';
  final kind = course.kcxzname.trim();
  if (itemName.startsWith('公共体育')) return kind.isEmpty ? '必修' : kind;
  if (beta) {
    final cat = course.kclbname.trim();
    if (cat.isNotEmpty &&
        normalizeCategory(cat) != normalizeCategory(itemName)) {
      return cat;
    }
  }
  return kind.isEmpty ? '必修' : kind;
}

/// 总成绩 <=59 或等级为 F：这门课没拿到学分。
///
/// P/F 课通过时学校给的 zcj 是 61，不会被误判成不及格；等级制的 A/A- 同理。
bool isCourseFailed(GradeCourse course) {
  final grade = course.zcjname1.trim().toUpperCase();
  if (grade == 'F') return true;
  final score = double.tryParse(course.zcj.trim());
  if (score != null) return score <= 59;
  return false;
}

/// 这门课实际能计入培养方案的学分：不及格记 0。
///
/// Flag-1029 关闭时退回旧行为——任何课程都按成绩单学分照算。
double courseCredits(GradeCourse course) {
  if (!_failedFilterEnabled()) return double.tryParse(course.xf) ?? 0;
  return isCourseFailed(course) ? 0 : (double.tryParse(course.xf) ?? 0);
}

bool _failedFilterEnabled() => FeatureGateService.instance.isEnabled(
  FeatureGateService.flag1029FailedCourses,
);

/// 同名课程重修通过后，旧的不及格记录不再占位。
///
/// 只丢弃「同名且有通过记录」的不及格课：像「美育实践」这种同名但分学期
/// 各修一次的课，两次都通过时仍然各算各的学分，不会被误合并。
List<GradeCourse> dropCoveredFailures(List<GradeCourse> grades) {
  if (!_failedFilterEnabled()) return grades;
  final passedNames = <String>{};
  for (final course in grades) {
    if (!isCourseFailed(course)) {
      passedNames.add(normalizeCategory(course.kcname));
    }
  }
  return <GradeCourse>[
    for (final course in grades)
      if (!(isCourseFailed(course) &&
          passedNames.contains(normalizeCategory(course.kcname))))
        course,
  ];
}

class ItemProgress {
  ItemProgress({
    required this.module,
    required this.item,
    required this.courses,
    required this.manualDone,
    required this.situationLectureDone,
    required this.situationSeminarDone,
  });

  final PlanModule module;
  final PlanItem item;
  final List<GradeCourse> courses;
  final bool manualDone;
  final bool situationLectureDone;
  final bool situationSeminarDone;

  String get key => itemKey(module.name, item.name);

  bool get manualCapable => kManualItems.contains(item.name);

  bool get isSituationAndPolicy => item.name == '形势与政策';

  String get situationLectureKey => '$key/形势与政策讲座';
  String get situationSeminarKey => '$key/形势与政策研讨';

  double get required => item.credits;

  double get earned {
    if (isSituationAndPolicy) {
      return situationLectureDone && situationSeminarDone ? required : 0;
    }
    if (manualCapable && manualDone) return required;
    var sum = 0.0;
    for (final c in courses) {
      sum += courseCredits(c);
    }
    return sum;
  }

  /// 在当前子项中实际可计入的学分。超出的课程仍保留在列表中，不能静默
  /// 当作没有修过：它可能是兴趣多修，或需要由用户决定能否改计其他项目。
  double get countedCredits => earned > required ? required : earned;

  /// 当前归类课程超过本子项学分上限的部分；这不是无效课程的结论。
  double get excessCredits => earned > required ? earned - required : 0;

  bool get satisfied => required <= 0 || earned + 1e-9 >= required;

  /// 已经修了但没修满：界面画圆圈，不画横线。
  bool get partial =>
      !satisfied &&
      (courses.isNotEmpty ||
          (isSituationAndPolicy &&
              (situationLectureDone || situationSeminarDone)));

  double get ratio {
    if (required <= 0) return 1;
    final r = earned / required;
    return r > 1 ? 1 : r;
  }
}

class ModuleProgress {
  ModuleProgress({required this.module, required this.items});

  final PlanModule module;
  final List<ItemProgress> items;

  double get required => module.credits;

  double get earned {
    var sum = 0.0;
    for (final it in items) {
      sum += it.countedCredits;
    }
    return sum;
  }

  double get ratio {
    if (required <= 0) return 1;
    final r = earned / required;
    return r > 1 ? 1 : r;
  }

  bool get satisfied => required <= 0 || earned + 1e-9 >= required;
}

/// 一次进度计算的全部产物。
class ProgressResult {
  ProgressResult({
    required this.major,
    required this.modules,
    required this.unmatched,
    required this.assigned,
    this.excluded = const <GradeCourse>[],
  });

  final PlanMajor major;
  final List<ModuleProgress> modules;

  /// 待归类课程：自动规则没命中，或用户主动「取消归类」踢回来的课程。
  final List<GradeCourse> unmatched;

  /// kth -> 命中的子项 key（含自动匹配与用户指定）
  final Map<String, String> assigned;

  /// 用户排除的课程：不参与任何学分累加，但仍在成绩单里。
  final List<GradeCourse> excluded;

  double get required => major.total;

  double get earned {
    var sum = 0.0;
    for (final m in modules) {
      if (m.module.countsTowardOverall) sum += m.earned;
    }
    return sum;
  }

  double get ratio {
    if (required <= 0) return 1;
    final r = earned / required;
    return r > 1 ? 1 : r;
  }

  Iterable<ItemProgress> get allItems => modules.expand((m) => m.items);
}

/// 按培养方案把成绩单课程分摊到子项。
///
/// 匹配优先级（自上而下，先命中先得）：
///   0. [excluded]：用户排除这门课 → 不参与任何累加，单独进「已排除课程」；
///   0b. [unclassified]：用户「取消归类」这门课 → 直接进「待归类课程」；
///   1. [overrides]：用户对**这一门课**（kth）手工指定的类别；
///   2. [rules] 里左边等于课程名的自定义组合；
///   3. [rules] 里左边等于课程类别名的自定义组合；
///   4. 课程类别名与子项名归一后**全字相等**；
///   5. 都不中 → 进「待归类」，由用户自己挑。
///
/// 前两条是用户的人工决定，永远压过后面所有自动规则；它们按 kth 存进
/// [ProgressState]，所以刷新成绩、重进页面都不会被自动规则重新抢走。
///
/// 第 4 步是唯一自动匹配，刻意保守：只认字面（允许少个「课」字），
/// 不做同义扩展，宁可漏判也不错配。
ProgressResult computeProgress({
  required PlanMajor major,
  required List<GradeCourse> grades,
  required Map<String, String> overrides,
  required Map<String, bool> manual,
  List<CustomRule> rules = const <CustomRule>[],
  Map<String, bool> excluded = const <String, bool>{},
  Map<String, bool> unclassified = const <String, bool>{},
}) {
  // 归一后的子项名 -> 候选 key 列表（同一专业内可能重名，按模块顺序先到先得）
  final byItemName = <String, List<String>>{};
  for (final module in major.modules) {
    for (final item in module.items) {
      byItemName
          .putIfAbsent(normalizeCategory(item.name), () => <String>[])
          .add(itemKey(module.name, item.name));
    }
  }

  final byCourseName = <String, String>{};
  final byCategoryName = <String, String>{};
  for (final rule in rules) {
    final left = normalizeCategory(rule.left);
    final right = rule.right;
    if (left.isEmpty || !_keyExists(major, right)) continue;
    byCourseName.putIfAbsent(left, () => right);
    byCategoryName.putIfAbsent(left, () => right);
  }

  final buckets = <String, List<GradeCourse>>{};
  final assigned = <String, String>{};
  final unmatched = <GradeCourse>[];
  final excludedCourses = <GradeCourse>[];

  // 重修通过后旧的不及格记录直接丢弃，不再参与匹配与学分累加。
  final effective = dropCoveredFailures(grades);

  for (final course in effective) {
    // 人工决定先于一切自动规则：排除 → 只记账不参与计算；
    // 取消归类 → 直接回到待归类，即使自动规则本来能命中。
    if (excluded[course.kth] == true) {
      excludedCourses.add(course);
      continue;
    }
    if (unclassified[course.kth] == true) {
      unmatched.add(course);
      continue;
    }

    String? hit;
    final isIdeologicalPractice =
        normalizeCategory(course.kcname) == normalizeCategory('思政实践课');
    final skipDefaultIdeologicalPractice =
        major.name == '马克思主义理论' && isIdeologicalPractice;
    final isSituationAndPolicy =
        normalizeCategory(course.kcname) == normalizeCategory('形势与政策') ||
        normalizeCategory(course.kclbname) == normalizeCategory('形势与政策');

    final override = overrides[course.kth];
    if (override != null && _keyExists(major, override)) {
      hit = override;
    }

    if (hit == null && byCourseName.isNotEmpty) {
      hit = byCourseName[normalizeCategory(course.kcname)];
    }
    if (hit == null && byCategoryName.isNotEmpty) {
      hit = byCategoryName[normalizeCategory(course.kclbname)];
    }
    if (hit == null &&
        !skipDefaultIdeologicalPractice &&
        !isSituationAndPolicy) {
      final keys = byItemName[normalizeCategory(course.kclbname)];
      if (keys != null && keys.isNotEmpty) {
        // 同名子项优先挑还没被填满的那个，避免全部堆进第一个模块
        hit = keys.firstWhere(
          (k) => _sumXf(buckets[k]) < _requiredOf(major, k),
          orElse: () => keys.first,
        );
      }
    }

    if (hit == null) {
      unmatched.add(course);
      continue;
    }
    buckets.putIfAbsent(hit, () => <GradeCourse>[]).add(course);
    assigned[course.kth] = hit;
  }

  final modules = <ModuleProgress>[];
  for (final module in progressModules(major)) {
    final items = <ItemProgress>[];
    for (final item in module.items) {
      final key = itemKey(module.name, item.name);
      items.add(
        ItemProgress(
          module: module,
          item: item,
          courses: buckets[key] ?? const <GradeCourse>[],
          manualDone: manual[key] ?? false,
          situationLectureDone: manual['$key/形势与政策讲座'] ?? false,
          situationSeminarDone: manual['$key/形势与政策研讨'] ?? false,
        ),
      );
    }
    modules.add(ModuleProgress(module: module, items: items));
  }

  return ProgressResult(
    major: major,
    modules: modules,
    unmatched: unmatched,
    assigned: assigned,
    excluded: excludedCourses,
  );
}

bool _keyExists(PlanMajor major, String key) {
  for (final module in major.modules) {
    for (final item in module.items) {
      if (itemKey(module.name, item.name) == key) return true;
    }
  }
  return false;
}

double _requiredOf(PlanMajor major, String key) {
  for (final module in major.modules) {
    for (final item in module.items) {
      if (itemKey(module.name, item.name) == key) return item.credits;
    }
  }
  return 0;
}

double _sumXf(List<GradeCourse>? courses) {
  if (courses == null) return 0;
  var sum = 0.0;
  for (final c in courses) {
    sum += courseCredits(c);
  }
  return sum;
}
