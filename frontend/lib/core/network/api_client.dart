import 'package:dio/dio.dart';
import 'dart:io';

import '../constants/api_path.dart';
import '../constants/api_token.dart';
import '../logger/app_logger.dart';
import '../../core/service/update_service.dart';

/// Dio HTTP 请求封装（macOS 优化版）
class ApiClient {
  static final ApiClient _instance = ApiClient._();
  factory ApiClient() => _instance;

  late final Dio dio;
  final _log = AppLogger('api_client');

  ApiClient._() {
    dio = Dio(
      BaseOptions(
        baseUrl: ApiPath.baseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 15),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        validateStatus: (status) => status != null && status < 500,
      ),
    );

    // 令牌拦截器：为每个请求附加本地后端访问令牌。
    // 必须放在最前（先于日志），且用拦截器而非静态 header——令牌在
    // App 启动过程中才生成，而 ApiClient 是单例、可能先被构造。
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final token = ApiToken.value;
          if (token.isNotEmpty) {
            options.headers[ApiToken.headerName] = token;
          }
          handler.next(options);
        },
      ),
    );

    // 日志拦截器：打印请求和响应（敏感字段脱敏）
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          _log.debug('${options.method} ${options.uri}');
          if (options.data != null) {
            _log.debug('Body: ${_redact(options.data)}');
          }
          handler.next(options);
        },
        onResponse: (response, handler) {
          _log.debug(
            'Response ${response.statusCode}: ${_truncate(_redact(response.data))}',
          );
          handler.next(response);
        },
        onError: (error, handler) {
          _log.error('HTTP Error: ${error.message}', error);
          if (error.response != null) {
            _log.error(
              'Status: ${error.response?.statusCode}, '
              'Body: ${_truncate(_redact(error.response?.data))}',
            );
          }
          if (error.error is SocketException) {
            _log.warning('Socket Error - backend may not be running');
          }
          handler.next(error);
        },
      ),
    );
  }

  /// 需要脱敏的字段名（登录密码不应以任何形式落盘到日志）
  static const Set<String> _secretKeys = {'password', 'token'};

  /// 递归替换敏感字段的值为 `***`
  ///
  /// 历史问题：日志拦截器原先把整个请求体 toString 打进 frontend.log，
  /// 登录请求体里的明文密码因此被长期写进日志文件。
  dynamic _redact(dynamic data) {
    if (data is Map) {
      final out = <String, dynamic>{};
      data.forEach((k, v) {
        final key = k.toString().toLowerCase();
        final isSecret = _secretKeys.any((s) => key.contains(s));
        out[k.toString()] = isSecret ? '***' : _redact(v);
      });
      return out;
    }
    if (data is List) return data.map(_redact).toList();
    return data;
  }

  String _truncate(dynamic data, [int maxLen = 500]) {
    final s = data?.toString() ?? '';
    return s.length > maxLen ? '${s.substring(0, maxLen)}...' : s;
  }

  // ---- Auth ----

  Future<Response> login(String username, String password) async {
    final resp = await dio.post(
      ApiPath.login,
      data: {'username': username, 'password': password},
    );
    // 全局 validateStatus 放行了 4xx，这里必须手动把失败状态转为异常，
    // 否则 401（密码错误）会被上层误判为登录成功
    if (resp.statusCode != null && resp.statusCode! >= 400) {
      throw DioException(
        requestOptions: resp.requestOptions,
        response: resp,
        type: DioExceptionType.badResponse,
      );
    }
    return resp;
  }

  /// 退出登录：后端会停止监控、清除已保存的凭据，并重置欢迎向导标记。
  Future<Response> logout() async {
    return dio.post(ApiPath.logout);
  }

  // ---- Data ----

  Future<Response> getGrades() async {
    UpdateService().reportQuery();
    return dio.get(ApiPath.grades);
  }

  Future<Response> getRank() async {
    UpdateService().reportQuery();
    return dio.get(ApiPath.rank);
  }

  /// 最近一次成绩/排名变动的通知内容（仪表板「最新动态」）
  Future<Response> getLatestChange() async {
    return dio.get(ApiPath.gradesLatestChange);
  }

  // ---- Settings ----

  Future<Response> getSettings() async {
    return dio.get(ApiPath.settings);
  }

  Future<Response> updateSettings(Map<String, dynamic> data) async {
    return dio.post(ApiPath.settings, data: data);
  }

  // ---- Monitor ----

  Future<Response> getMonitorStatus() async {
    return dio.get(ApiPath.monitorStatus);
  }

  Future<Response> startMonitor() async {
    return dio.post(ApiPath.monitorStart);
  }

  Future<Response> stopMonitor() async {
    return dio.post(ApiPath.monitorStop);
  }

  Future<Response> restartMonitor() async {
    return dio.post(ApiPath.monitorRestart);
  }

  // ---- Notification ----

  Future<Response> sendTestNotification() async {
    return dio.post(ApiPath.notificationTest);
  }

  Future<Response> getNotificationPreview(String mode) async {
    return dio.get(
      ApiPath.notificationPreview,
      queryParameters: {'mode': mode},
    );
  }

  // ---- Dev Tools ----

  Future<Response> queryOnce() async {
    UpdateService().reportQuery();
    return dio.post(ApiPath.devQueryOnce);
  }

  Future<Response> clearCache() async {
    return dio.post(ApiPath.devClearCache);
  }

  Future<Response> clearAllData() async {
    return dio.post(ApiPath.devClearAllData);
  }

  Future<Response> openLogDir() async {
    return dio.get(ApiPath.devOpenLogDir);
  }

  // ---- Welcome ----

  Future<Response> getWelcomeStatus() async {
    return dio.get(ApiPath.welcomeStatus);
  }

  Future<Response> completeWelcome() async {
    return dio.post(ApiPath.welcomeComplete);
  }
}
