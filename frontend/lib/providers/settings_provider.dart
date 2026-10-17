import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/network/api_client.dart';
import '../core/logger/app_logger.dart';
import 'monitor_provider.dart';

/// 设置数据模型
class AppSettings {
  final String username;
  final String password;
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
      password: json['password']?.toString() ?? '',
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
      'password': password,
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
  const LoginResult({required this.success, required this.message});
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
      return const LoginResult(success: true, message: '登录验证成功，凭据已自动保存');
    } on DioException catch (e) {
      _log.error('DioException: ${e.message}', e);
      if (e.type == DioExceptionType.connectionTimeout) {
        return const LoginResult(success: false, message: '连接超时，请确认后端服务已启动');
      } else if (e.type == DioExceptionType.receiveTimeout) {
        return const LoginResult(
          success: false,
          message: '服务器响应超时，登录接口处理较慢，请稍后重试',
        );
      } else if (e.type == DioExceptionType.connectionError) {
        return const LoginResult(
          success: false,
          message: '无法连接后端服务 (127.0.0.1:18923)',
        );
      } else if (e.response?.statusCode == 401) {
        return const LoginResult(
          success: false,
          message: '账号或密码错误，请检查您的账号密码是否正确',
        );
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
