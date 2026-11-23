import 'dart:convert';
import 'dart:io';

/// UI 层轻量本地偏好（与后端无关的显示状态）
///
/// 存储：`~/Library/Application Support/GradeMonitor/ui_prefs.json`
/// （Windows: `%APPDATA%\GradeMonitor\ui_prefs.json`）
///
/// 两类用途：
///   - 提示横条「不再显示」的永久记录（`dismissed_banners`）。「叉」是单次
///     隐藏（仅内存，重开 App 恢复），「不再显示」写入本文件。
///   - 通用布尔/字符串偏好（`prefs`）。用于跨重启保持的界面状态，例如
///     开发者选项是否常驻、轮询秒数输入框的上次值。
class UiPrefsService {
  UiPrefsService._();

  /// 开发者选项是否常驻：一旦解锁成功就置真，只有手动「关闭开发者选项」才置假。
  ///
  /// 存在的理由：后端凭据读取失败（钥匙串拒绝、用户清空）时
  /// `/api/developer/status` 会回 `unlocked:false`，若只信后端就会把面板
  /// 悄悄收起来，与"除非手动关闭否则不隐藏"的预期相反。
  static const String prefDevPanelPinned = 'dev_panel_pinned';

  /// 开发者选项里「轮询秒数」输入框的上次值（跨重启、跨选项卡保持）。
  static const String prefDevIntervalSeconds = 'dev_interval_seconds';

  /// 用户选中的视觉主题与明暗模式（system / light / dark）。
  static const String prefThemePreset = 'theme_preset';
  static const String prefThemeMode = 'theme_mode';

  static const String _fileName = 'ui_prefs.json';

  /// 永久隐藏的提示条 key 集合
  static final Set<String> _permanentDismissed = <String>{};

  /// 通用偏好（字符串化存储，读取时按需转型）
  static final Map<String, String> _prefs = <String, String>{};

  /// 单次隐藏的提示条 key 集合（仅本次运行会话有效）
  static final Set<String> sessionDismissed = <String>{};

  static bool _loaded = false;
  static bool get loaded => _loaded;

  /// 测试用：把落盘路径改到临时文件，避免测试写到真实用户的偏好里。
  ///
  /// 只在 `test/` 里设置；生产代码从不赋值，保持 null 即走正常路径。
  static String? debugFilePath;

  static String? _resolvePath() {
    final override = debugFilePath;
    if (override != null && override.isNotEmpty) return override;
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isEmpty) return null;
      return '$home/Library/Application Support/GradeMonitor/$_fileName';
    }
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      return '$appData\\GradeMonitor\\$_fileName';
    }
    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) return null;
    return '$home/.grademonitor/$_fileName';
  }

  /// 确保已从磁盘载入（幂等）
  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final path = _resolvePath();
      if (path == null) return;
      final file = File(path);
      if (!file.existsSync()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is Map) {
        final list = raw['dismissed_banners'];
        if (list is List) {
          _permanentDismissed.addAll(list.map((e) => e.toString()));
        }
        final prefs = raw['prefs'];
        if (prefs is Map) {
          for (final entry in prefs.entries) {
            _prefs[entry.key.toString()] = entry.value.toString();
          }
        }
      }
    } catch (_) {
      // 载入失败按"无记录"处理，不影响功能
    }
  }

  /// 读一个通用偏好；不存在时返回 [fallback]。
  static String? readPref(String key, {String? fallback}) =>
      _prefs[key] ?? fallback;

  /// 读布尔偏好；无法解析时返回 [fallback]。
  static bool readBoolPref(String key, {bool fallback = false}) {
    final raw = _prefs[key];
    if (raw == null) return fallback;
    return raw == 'true';
  }

  /// 写一个通用偏好（落盘）。写入失败仅影响"记住"，不阻塞交互。
  static Future<void> writePref(String key, String value) async {
    _prefs[key] = value;
    await _flush();
  }

  static Future<void> writeBoolPref(String key, bool value) =>
      writePref(key, value ? 'true' : 'false');

  /// 把当前全部偏好写回磁盘（同时保留提示条的永久隐藏记录）。
  static Future<void> _flush() async {
    try {
      final path = _resolvePath();
      if (path == null) return;
      final file = File(path);
      final parent = file.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'dismissed_banners': _permanentDismissed.toList(),
          'prefs': _prefs,
        }),
      );
    } catch (_) {
      // 写盘失败仅影响"记住"，不阻塞交互
    }
  }

  static bool isPermanentlyDismissed(String key) =>
      _permanentDismissed.contains(key);

  /// 单次隐藏（不落盘，重开 App 恢复）
  static void dismissForSession(String key) => sessionDismissed.add(key);

  /// 永久隐藏（落盘）
  static Future<void> dismissPermanently(String key) async {
    _permanentDismissed.add(key);
    await _flush();
  }

  static Future<void> restorePermanentlyDismissed(String key) async {
    if (_permanentDismissed.remove(key)) await _flush();
  }
}
