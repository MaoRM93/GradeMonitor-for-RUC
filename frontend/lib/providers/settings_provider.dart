import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/network/api_client.dart';
import '../core/logger/app_logger.dart';
import 'monitor_provider.dart';

/// 设置数据模型
///
/// 安全约定（2026-11 加固）：**密码不随设置读写往返**。
/// - 后端永不把密码回传给前端（凭证存在系统钥匙串/DPAPI 中）；
/// - 前端只在用户"登录并保存"时显式提交一次密码；
/// - 其余任何保存（开关/间隔/时段等）都不带 password 字段，后端据此保持
///   既有密码不变。
/// [hasPassword] 表示后端是否已保存密码，供 UI 显示占位提示。
class AppSettings {
  final String username;
  final String password;
  final bool hasPassword;
  final bool rememberMe;
  final String notifyMode;
  final String startTime;
  final String endTime;
  final int intervalSeconds;
  final bool autoStart;
  final bool autoMonitorEnabled;
  final bool rankMonitorEnabled;
  final bool showMenubarIcon;
  final bool hideUnknownCourses;
  final bool randomIntervalEnabled;
  final bool welcomeCompleted;
  final bool showWelcomeAlways;

  const AppSettings({
    this.username = '',
    this.password = '',
    this.hasPassword = false,
    this.rememberMe = false,
    this.notifyMode = '详细',
    this.startTime = '08:00',
    this.endTime = '23:00',
    this.intervalSeconds = 300,
    this.autoStart = false,
    this.autoMonitorEnabled = false,
    this.rankMonitorEnabled = false,
    this.showMenubarIcon = true,
    this.hideUnknownCourses = true,
    this.randomIntervalEnabled = true,
    this.welcomeCompleted = false,
    this.showWelcomeAlways = false,
  });

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      username: json['username']?.toString() ?? '',
      // 后端不再回传密码，仅给 has_password 标记
      password: json['password']?.toString() ?? '',
      hasPassword: json['has_password'] ?? false,
      rememberMe: json['remember_me'] ?? false,
      notifyMode: json['notify_mode']?.toString() ?? '详细',
      startTime: json['start_time']?.toString() ?? '08:00',
      endTime: json['end_time']?.toString() ?? '23:00',
      intervalSeconds: json['interval_seconds'] ?? 300,
      autoStart: json['auto_start'] ?? false,
      autoMonitorEnabled: json['auto_monitor_enabled'] ?? false,
      rankMonitorEnabled: json['rank_monitor_enabled'] ?? false,
      showMenubarIcon: json['show_menubar_icon'] ?? true,
      hideUnknownCourses: json['hide_unknown_courses'] ?? true,
      randomIntervalEnabled: json['random_interval_enabled'] ?? true,
      welcomeCompleted: json['welcome_completed'] ?? false,
      showWelcomeAlways: json['show_welcome_always'] ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'username': username,
      // 仅当本对象持有非空密码时才提交（登录动作显式赋值）；
      // 普通保存为 '' → 不带该键，后端保持既有密码不被清除。
      if (password.isNotEmpty) 'password': password,
      'remember_me': rememberMe,
      'notify_mode': notifyMode,
      'start_time': startTime,
      'end_time': endTime,
      'interval_seconds': intervalSeconds,
      'auto_start': autoStart,
      'auto_monitor_enabled': autoMonitorEnabled,
      'rank_monitor_enabled': rankMonitorEnabled,
      'show_menubar_icon': showMenubarIcon,
      'hide_unknown_courses': hideUnknownCourses,
      'random_interval_enabled': randomIntervalEnabled,
      'welcome_completed': welcomeCompleted,
      'show_welcome_always': showWelcomeAlways,
    };
  }

  AppSettings copyWith({
    String? username,
    String? password,
    bool? hasPassword,
    bool? rememberMe,
    String? notifyMode,
    String? startTime,
    String? endTime,
    int? intervalSeconds,
    bool? autoStart,
    bool? autoMonitorEnabled,
    bool? rankMonitorEnabled,
    bool? showMenubarIcon,
    bool? hideUnknownCourses,
    bool? randomIntervalEnabled,
    bool? welcomeCompleted,
    bool? showWelcomeAlways,
  }) {
    return AppSettings(
      username: username ?? this.username,
      password: password ?? this.password,
      hasPassword: hasPassword ?? this.hasPassword,
      rememberMe: rememberMe ?? this.rememberMe,
      notifyMode: notifyMode ?? this.notifyMode,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      intervalSeconds: intervalSeconds ?? this.intervalSeconds,
      autoStart: autoStart ?? this.autoStart,
      autoMonitorEnabled: autoMonitorEnabled ?? this.autoMonitorEnabled,
      rankMonitorEnabled: rankMonitorEnabled ?? this.rankMonitorEnabled,
      showMenubarIcon: showMenubarIcon ?? this.showMenubarIcon,
      hideUnknownCourses: hideUnknownCourses ?? this.hideUnknownCourses,
      welcomeCompleted: welcomeCompleted ?? this.welcomeCompleted,
      showWelcomeAlways: showWelcomeAlways ?? this.showWelcomeAlways,
    );
  }
}

/// 登录结果
class LoginResult {
  final bool success;
  final String message;
  /// 失败分类：credentials / maintenance / network（null 表示非后端分类的失败）
  final String? kind;
  const LoginResult({required this.success, required this.message, this.kind});
}

/// 登录失败文案（与 `backend/auth/login.py` 的 USER_MESSAGES 保持一致，
/// 仅在拿不到后端文案时兜底）
class LoginErrorText {
  static const String credentials = '您输入的账号或密码错误，请检查后重试';
  static const String maintenance = '教务系统正在维护中，请稍候';
  static const String network = '无法连接到服务器，请检查您的网络连接';

  static String of(String? kind) {
    switch (kind) {
      case 'credentials':
        return credentials;
      case 'maintenance':
        return maintenance;
      case 'network':
        return network;
      default:
        return credentials;
    }
  }

  /// 从后端 401 响应体里解析出 (kind, 文案)。
  /// 后端形状：{"detail": {"kind": "...", "message": "...", "detail": "..."}}
  /// 拿不到结构时退回 [of] 的兜底文案。
  static (String? kind, String message) fromResponse(dynamic data) {
    String? kind;
    String? message;
    if (data is Map) {
      final detail = data['detail'];
      if (detail is Map) {
        kind = detail['kind'] as String?;
        message = detail['message'] as String?;
      }
    }
    if (message == null || message.isEmpty) {
      message = of(kind);
    }
    return (kind, message);
  }
}

/// 设置 Provider
class SettingsNotifier extends StateNotifier<AppSettings> {
  final ApiClient _api;
  final _log = AppLogger('settings');

  SettingsNotifier(this._api) : super(const AppSettings());

  Future<void> fetchSettings() async {
    try {
      final resp = await _api.getSettings();
      state = AppSettings.fromJson(resp.data as Map<String, dynamic>);
      _log.debug('设置已加载');
    } catch (e) {
      _log.error('fetchSettings error', e);
    }
  }

  Future<bool> saveSettings(AppSettings settings) async {
    try {
      await _api.updateSettings(settings.toJson());
      state = settings;
      _log.info('设置已保存');
      return true;
    } catch (e) {
      _log.error('saveSettings error', e);
      return false;
    }
  }

  Future<LoginResult> login(String username, String password) async {
    _log.info('尝试登录: $username');
    try {
      await _api.login(username, password);
      _log.info('登录成功');
      // 登录验证通过后立即把凭据交给后端安全存储（钥匙串/DPAPI）。
      // 这是**唯一**会向后端提交密码的路径。
      await _api.updateSettings({
        'username': username,
        'password': password,
        'remember_me': true,
      });
      _log.info('凭据已交由后端安全存储保存');
      return const LoginResult(success: true, message: '登录验证成功，凭据已自动保存');
    } on DioException catch (e) {
      _log.error('DioException: ${e.message}', e);
      // 连不上后端 / 超时，本质上都属于「网络不通」，统一用同一句文案，
      // 技术细节留在日志里（不再把 127.0.0.1:18923 这种内部地址抛给用户）。
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.unknown) {
        _log.warning('网络层失败（${e.type}），按 network 处理');
        return const LoginResult(
          success: false,
          message: LoginErrorText.network,
          kind: 'network',
        );
      } else if (e.response?.statusCode == 401) {
        // 后端把失败分成三类（凭据错误 / 维护中 / 网络不通），
        // 这里按 kind 原样使用后端给的中文文案，不再一律报「密码错误」。
        final (kind, message) = LoginErrorText.fromResponse(e.response?.data);
        _log.warning('登录失败 [$kind]: $message');
        return LoginResult(success: false, message: message, kind: kind);
      } else {
        return LoginResult(
          success: false,
          message: '登录失败：${e.message ?? '未知错误'}',
        );
      }
    } catch (e) {
      _log.error('login error', e);
      return LoginResult(success: false, message: '登录失败：${e.toString()}');
    }
  }
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, AppSettings>((
  ref,
) {
  final api = ref.watch(apiClientProvider);
  return SettingsNotifier(api);
});
