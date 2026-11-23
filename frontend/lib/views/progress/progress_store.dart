import 'dart:convert';

import '../../core/service/ui_prefs_service.dart';

/// 一条「自定义组合」规则：`（左边）=（右边）`。
///
/// 左边可以是成绩单里的课程名，也可以是课程类别名；右边是培养方案子项的 key。
/// 用户用它把系统不敢自动判断的课程手工挂到某个子项上，而且**一次管一类**，
/// 不必逐门课点选。
class CustomRule {
  const CustomRule({required this.left, required this.right});

  final String left;
  final String right;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'left': left,
    'right': right,
  };

  static CustomRule? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final left = (raw['left'] ?? '').toString();
    final right = (raw['right'] ?? '').toString();
    if (left.isEmpty || right.isEmpty) return null;
    return CustomRule(left: left, right: right);
  }
}

/// 修读进度的本地解释层：课程类别覆盖 + 实践项勾选 + 免修说明 + 自定义组合。
///
/// 只存"用户对本地进度的解释"，不改写成绩单原始数据；键按年级+专业分开，
/// 换专业不会串味。
class ProgressState {
  ProgressState({
    Map<String, String>? overrides,
    Map<String, bool>? manual,
    List<CustomRule>? rules,
    this.note = '',
  }) : overrides = overrides ?? <String, String>{},
       manual = manual ?? <String, bool>{},
       rules = rules ?? <CustomRule>[];

  /// kth -> 培养方案子项 key（用户手工指定的课程类别）
  final Map<String, String> overrides;

  /// 培养方案子项 key -> 是否已完成（实践、论文、实习等非课程项）
  final Map<String, bool> manual;

  /// 自定义组合规则（左边 = 右边）
  final List<CustomRule> rules;

  /// 免修与替代说明（自由文本）
  String note;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'overrides': overrides,
    'manual': manual,
    'rules': [for (final r in rules) r.toJson()],
    'note': note,
  };

  static ProgressState fromJson(Map<String, dynamic> raw) {
    final overrides = <String, String>{};
    final manual = <String, bool>{};
    final rules = <CustomRule>[];
    final rawOverrides = raw['overrides'];
    if (rawOverrides is Map) {
      for (final entry in rawOverrides.entries) {
        overrides[entry.key.toString()] = entry.value.toString();
      }
    }
    final rawManual = raw['manual'];
    if (rawManual is Map) {
      for (final entry in rawManual.entries) {
        manual[entry.key.toString()] = entry.value == true;
      }
    }
    final rawRules = raw['rules'];
    if (rawRules is List) {
      for (final item in rawRules) {
        final rule = CustomRule.fromJson(item);
        if (rule != null) rules.add(rule);
      }
    }
    return ProgressState(
      overrides: overrides,
      manual: manual,
      rules: rules,
      note: raw['note']?.toString() ?? '',
    );
  }
}

/// 进度状态的读写（落 ui_prefs.json，与提示条隐藏记录同一份文件）。
class ProgressStore {
  ProgressStore._();

  /// 「高级分类[Beta]」的本地开关；缺省关闭，与功能组开关 Flag-1026 一起决定。
  static const String prefAdvancedClassify = 'progress_advanced_classify';

  static String _stateKey(String year, String major) =>
      'progress_state_${year}_$major';

  static String _majorKey(String year) => 'progress_major_$year';

  static ProgressState load(String year, String major) {
    final raw = UiPrefsService.readPref(_stateKey(year, major));
    if (raw == null || raw.isEmpty) return ProgressState();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return ProgressState.fromJson(decoded);
      if (decoded is Map) {
        return ProgressState.fromJson(decoded.cast<String, dynamic>());
      }
    } catch (_) {
      // 记录损坏按"无覆盖"处理，不影响页面
    }
    return ProgressState();
  }

  static Future<void> save(String year, String major, ProgressState state) =>
      UiPrefsService.writePref(
        _stateKey(year, major),
        jsonEncode(state.toJson()),
      );

  static String? loadMajor(String year) => UiPrefsService.readPref(_majorKey(year));

  static Future<void> saveMajor(String year, String major) =>
      UiPrefsService.writePref(_majorKey(year), major);

  static bool loadAdvancedClassify() =>
      UiPrefsService.readBoolPref(prefAdvancedClassify, fallback: false);

  static Future<void> saveAdvancedClassify(bool value) =>
      UiPrefsService.writeBoolPref(prefAdvancedClassify, value);
}
