import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../../providers/grades_provider.dart';
import 'progress_store.dart';

/// 培养方案修读要求的结构化数据（由 scripts/build_curriculum_plan.py 离线生成）。
///
/// 运行时不解析 PDF：后端与前端都不引入 PDF 依赖，这里只读构建产物
/// `assets/curricula/curriculum_plan.json`。
class PlanItem {
  const PlanItem({required this.name, required this.credits});

  final String name;
  final double credits;
}

class PlanModule {
  const PlanModule({
    required this.name,
    required this.credits,
    required this.items,
  });

  final String name;
  final double credits;
  final List<PlanItem> items;
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
const Set<String> kManualItems = <String>{
  '研究训练',
  '专业实习',
  '毕业论文',
  '毕业论文（设计）',
  '专业实践活动',
  '专业特色创新训练',
  '国际性学习课程',
  '创新引导课',
  '志愿服务',
  '劳动教育',
  '马克思主义经典著作研读营',
};

String itemKey(String module, String item) => '$module/$item';

/// 培养方案里的一个子项在界面上的选项（自定义组合右侧下拉用）。
class ItemOption {
  const ItemOption({required this.key, required this.module, required this.item});

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
    if (cat.isNotEmpty && normalizeCategory(cat) != normalizeCategory(itemName)) {
      return cat;
    }
  }
  return kind.isEmpty ? '必修' : kind;
}

class ItemProgress {
  ItemProgress({
    required this.module,
    required this.item,
    required this.courses,
    required this.manualDone,
  });

  final PlanModule module;
  final PlanItem item;
  final List<GradeCourse> courses;
  final bool manualDone;

  String get key => itemKey(module.name, item.name);

  bool get manualCapable => kManualItems.contains(item.name);

  double get required => item.credits;

  double get earned {
    if (manualCapable && manualDone) return required;
    var sum = 0.0;
    for (final c in courses) {
      sum += double.tryParse(c.xf) ?? 0;
    }
    return sum;
  }

  bool get satisfied => required <= 0 || earned + 1e-9 >= required;

  /// 已经修了但没修满：界面画圆圈，不画横线。
  bool get partial => !satisfied && courses.isNotEmpty;

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
      sum += it.earned > it.required ? it.required : it.earned;
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
  });

  final PlanMajor major;
  final List<ModuleProgress> modules;

  /// 未能自动归类、也未被用户指定类别的课程
  final List<GradeCourse> unmatched;

  /// kth -> 命中的子项 key（含自动匹配与用户指定）
  final Map<String, String> assigned;

  double get required => major.total;

  double get earned {
    var sum = 0.0;
    for (final m in modules) {
      sum += m.earned;
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
///   1. [overrides]：用户对**这一门课**（kth）手工指定的类别；
///   2. [rules] 里左边等于课程名的自定义组合；
///   3. [rules] 里左边等于课程类别名的自定义组合；
///   4. 课程类别名与子项名归一后**全字相等**；
///   5. 都不中 → 进「未归类」，由用户自己挑。
///
/// 第 4 步是唯一自动匹配，刻意保守：只认字面（允许少个「课」字），
/// 不做同义扩展，宁可漏判也不错配。
ProgressResult computeProgress({
  required PlanMajor major,
  required List<GradeCourse> grades,
  required Map<String, String> overrides,
  required Map<String, bool> manual,
  List<CustomRule> rules = const <CustomRule>[],
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

  for (final course in grades) {
    String? hit;

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
    if (hit == null) {
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
  for (final module in major.modules) {
    final items = <ItemProgress>[];
    for (final item in module.items) {
      final key = itemKey(module.name, item.name);
      items.add(
        ItemProgress(
          module: module,
          item: item,
          courses: buckets[key] ?? const <GradeCourse>[],
          manualDone: manual[key] ?? false,
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
    sum += double.tryParse(c.xf) ?? 0;
  }
  return sum;
}
