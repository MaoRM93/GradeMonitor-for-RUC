import 'dart:convert';
import 'dart:io';

/// UI 层轻量本地偏好（与后端无关的显示状态）
///
/// 存储：`~/Library/Application Support/GradeMonitor/ui_prefs.json`
/// （Windows: `%APPDATA%\GradeMonitor\ui_prefs.json`）
///
/// 当前用途：提示横条「不再显示」的永久记录。
/// 「叉」是单次隐藏（仅内存，重开 App 恢复），「不再显示」写入本文件。
class UiPrefsService {
  UiPrefsService._();

  static const String _fileName = 'ui_prefs.json';

  /// 永久隐藏的提示条 key 集合
  static final Set<String> _permanentDismissed = <String>{};

  /// 单次隐藏的提示条 key 集合（仅本次运行会话有效）
  static final Set<String> sessionDismissed = <String>{};

  static bool _loaded = false;
  static bool get loaded => _loaded;

  static String? _resolvePath() {
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
      }
    } catch (_) {
      // 载入失败按"无记录"处理，不影响功能
    }
  }

  static bool isPermanentlyDismissed(String key) =>
      _permanentDismissed.contains(key);

  /// 单次隐藏（不落盘，重开 App 恢复）
  static void dismissForSession(String key) => sessionDismissed.add(key);

  /// 永久隐藏（落盘）
  static Future<void> dismissPermanently(String key) async {
    _permanentDismissed.add(key);
    try {
      final path = _resolvePath();
      if (path == null) return;
      final file = File(path);
      final parent = file.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      await file.writeAsString(
        jsonEncode({'dismissed_banners': _permanentDismissed.toList()}),
      );
    } catch (_) {
      // 写盘失败仅影响"记住"，不阻塞交互
    }
  }
}
