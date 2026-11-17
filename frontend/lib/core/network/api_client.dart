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
        // 4xx 是明确失败，必须走 onError/catch。把它当作成功响应会让开发者
        // 面板在 403/400 时保留乐观状态，甚至错误提示“已下发”。
        validateStatus: (status) => status != null && status < 400,
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
  static const Set<String> _secretKeys = {
    'password',
    'token',
    'url',
    'topic',
    'nickname',
  };

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

  /// 将后端的可展示错误压缩为一条人话，避免 UI 直接露出 Dio 的长堆栈。
  /// 后端规范错误放在 `{"detail": "…"}` 中，优先保留该信息。
  String errorMessage(Object error, {String fallback = '请求失败'}) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map && data['detail'] != null) {
        return data['detail'].toString();
      }
      final status = error.response?.statusCode;
      if (status != null) return '$fallback（HTTP $status）';
    }
    return fallback;
  }

  // ---- Auth ----

  /// 登录
  ///
  /// [mode] 登录入口：`jw`（教务系统直连，默认）/ `cas`（统一身份认证）/
  /// `vruc`（传统）。[captcha] 验证码文本，[captchaId] 为取码时返回的
  /// 会话 id —— 必须一起回传，因为验证码与服务端会话绑定。
  Future<Response> login(
    String username,
    String password, {
    String mode = 'jw',
    String captcha = '',
    String captchaId = '',
  }) async {
    final resp = await dio.post(
      ApiPath.login,
      data: {
        'username': username,
        'password': password,
        'mode': mode,
        'captcha': captcha,
        'captcha_id': captchaId,
      },
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

  /// 获取登录入口列表（欢迎向导「选择登录入口」页用）
  Future<Response> getLoginModes() async {
    return dio.get(ApiPath.loginModes);
  }

  /// 获取登录验证码（base64 内联图片 + 会话 id）
  Future<Response> getLoginCaptcha({String mode = 'jw'}) async {
    return dio.post(ApiPath.loginCaptcha, data: {'mode': mode});
  }

  /// 查询本地保存的登录会话是否仍可用（免登录）
  Future<Response> getSessionStatus() async {
    return dio.get(ApiPath.sessionStatus);
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

  Future<Response> getNotificationForwarders() =>
      dio.get(ApiPath.notificationForwarders);
  Future<Response> updateNotificationForwarders(Map<String, dynamic> data) =>
      dio.post(ApiPath.notificationForwarders, data: data);
  Future<Response> testNotificationForwarder(String channel) =>
      dio.post('${ApiPath.notificationForwarders}/$channel/test');

  Future<Response> getDeveloperStatus() => dio.get(ApiPath.developerStatus);

  /// 用 GitHub 身份登录开发者模式。
  ///
  /// 三个字段严格对应 UI 上仅有的三个标签（[mngId] = LoginMngID、
  /// [account] = Account、[token] = Password）。GitHub 没有"账号 + 密码
  /// 换令牌"的 API，所以 Password 语义上是 GitHub 令牌。
  Future<Response> loginDeveloper({
    required String mngId,
    required String account,
    required String token,
  }) => dio.post(
    ApiPath.developerLogin,
    data: {'mng_id': mngId, 'account': account, 'token': token},
  );

  Future<Response> logoutDeveloper() => dio.post(ApiPath.developerLogout);
  Future<Response> getDeveloperFlags() => dio.get(ApiPath.developerFlags);
  Future<Response> setDeveloperFlag(String name, bool value) =>
      dio.post(ApiPath.developerFlags, data: {'name': name, 'value': value});

  /// 功能组开关（Flag-1xxx）注册表 + 当前状态。
  ///
  /// 与 [getDeveloperFlags] 是两套：那边是开发者面板的调谐按钮，
  /// 这边是产品功能的下线闸门。该端点不需要开发者解锁。
  Future<Response> getFeatures() => dio.get(ApiPath.features);

  /// 写入功能组开关；[gates] 非空时走批量覆盖，否则按单条写。
  Future<Response> setFeatureGate(String id, bool value) =>
      dio.post(ApiPath.developerFeatures, data: {'id': id, 'value': value});

  Future<Response> setFeatureGates(Map<String, bool> gates) =>
      dio.post(ApiPath.developerFeatures, data: {'gates': gates});

  /// 签发一条远程功能开关指令（`control-v<rev>` 独立频道）。
  ///
  /// [push] 为 false 时只在本地生成签名块、不推 GitHub —— 用于先人工核对
  /// 内容再决定是否真的下发。令牌留空则后端复用登录时存入系统凭据的那枚。
  Future<Response> publishGates({
    required Map<String, bool> gates,
    int rev = 0,
    bool push = true,
    String githubToken = '',
  }) => dio.post(
    ApiPath.developerGatesPublish,
    data: {
      'gates': gates,
      'rev': rev,
      'push': push,
      'github_token': githubToken,
    },
  );

  Future<Response> publishDeveloperNotice({
    required String channel,
    required String title,
    required String body,
  }) => dio.post(
    ApiPath.developerNoticePublish,
    data: {'channel': channel, 'title': title, 'body': body},
  );

  Future<Response> getDeveloperNotices() => dio.get(ApiPath.developerNotices);

  Future<Response> recallDeveloperNotice(String id) =>
      dio.post('${ApiPath.developerNotices}/$id/recall');

  /// 打开培养方案。
  ///
  /// [grade] 为 null 时不发送请求体 —— 后端据此沿用账号匹配逻辑，
  /// 与老版本调用完全一致；显式传年级时才发 `{"grade": "..."}`。
  Future<Response> openCurriculum({String? grade}) => dio.post(
    ApiPath.curriculumOpen,
    data: grade == null ? null : {'grade': grade},
  );

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
