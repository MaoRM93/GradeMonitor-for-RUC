import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, Process;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/constants/api_path.dart';
import '../logger/app_logger.dart';

/// 更新检查结果
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.success,
    required this.hasUpdate,
    this.message,
    this.currentVersion = '',
    this.latestVersion = '',
    this.releaseNotes = '',
    this.downloadUrl = '',
  });

  /// 请求与解析是否成功（失败时 [message] 说明原因）
  final bool success;

  /// 是否存在新版本
  final bool hasUpdate;

  /// 失败原因（手动检查时提示用户）
  final String? message;

  /// 当前运行版本，形如 106.0.0.105
  final String currentVersion;

  /// 最新发布版本
  final String latestVersion;

  /// Release 说明（Markdown 纯文本展示）
  final String releaseNotes;

  /// 下载地址：优先 macOS zip 资产，其次 Release 页面
  final String downloadUrl;
}

/// GitHub Release 更新检查服务
///
/// - 每 1 小时自动检查一次，失败静默，不打扰用户
/// - 手动检查返回完整结果，由调用方决定是否提示
/// - 超时 20 秒，失败后最多重试 3 次
class UpdateService {
  static final UpdateService _instance = UpdateService._();
  factory UpdateService() => _instance;
  UpdateService._() {
    _dio = Dio(
      BaseOptions(
        connectTimeout: _timeout,
        receiveTimeout: _timeout,
        sendTimeout: _timeout,
        headers: {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'GradeMonitor-UpdateCheck',
        },
        validateStatus: (status) => status != null && status < 500,
      ),
    );
  }

  static const String repoOwner = 'MaoRM93';
  static const String repoName = 'GradeMonitor-for-RUC';
  static const String repoUrl = 'https://github.com/$repoOwner/$repoName';

  /// GitHub API 地址（必须是 api.github.com；github.com 的 releases/latest
  /// 是网页，返回 HTML，无法当 JSON 解析）
  static const String _apiUrl =
      'https://api.github.com/repos/$repoOwner/$repoName/releases/latest';

  /// 停用开关：GitHub 最新 Release 检测到此版本号时全屏禁用应用
  static const String killSwitchVersion = '114.514';

  static const Duration _timeout = Duration(seconds: 20);
  static const int _maxRetries = 3;
  static const Duration _retryDelay = Duration(seconds: 2);
  static const Duration _checkInterval = Duration(hours: 1);

  /// 防滥用检查周期：低频轮询后端滥用标记（开销可忽略）
  static const Duration _abuseCheckInterval = Duration(seconds: 30);

  final _log = AppLogger('update');
  late final Dio _dio;
  Timer? _timer;
  Timer? _abuseTimer;
  bool _checking = false;
  String _currentVersion = '';

  /// 已提醒过的版本号，避免同一次运行内 1 小时重复弹窗
  String? _notifiedVersion;

  /// 全局禁用状态 — main.dart 监听并切换到禁用页
  final ValueNotifier<bool> disabled = ValueNotifier<bool>(false);

  String get currentVersion => _currentVersion;

  /// 发行状态：'Release' 正式版 / 'Beta' 测试版（主页左下角展示，发布时手动更新）
  // ignore: constant_identifier_names
  static const String VerStatus = 'Release';

  /// 加载并缓存当前应用版本（major.minor.patch.build）
  Future<String> loadCurrentVersion() async {
    if (_currentVersion.isNotEmpty) return _currentVersion;
    try {
      final info = await PackageInfo.fromPlatform();
      final build = info.buildNumber.trim();
      _currentVersion = build.isEmpty ? info.version : '${info.version}.$build';
      _log.info('当前应用版本: $_currentVersion');
    } catch (e) {
      _log.warning('读取应用版本失败: $e');
    }
    return _currentVersion;
  }

  /// 启动定时检查：首次延迟 5 秒（避开启动高峰），此后每 1 小时一次
  void startPeriodicCheck({
    required void Function(UpdateCheckResult result) onUpdateAvailable,
  }) {
    _timer?.cancel();
    _timer = Timer.periodic(
      _checkInterval,
      (_) => _autoCheck(onUpdateAvailable),
    );
    Future.delayed(
      const Duration(seconds: 5),
      () => _autoCheck(onUpdateAvailable),
    );
    _startAbuseWatch();
  }

  void stopPeriodicCheck() {
    _timer?.cancel();
    _timer = null;
    _abuseTimer?.cancel();
    _abuseTimer = null;
  }

  /// 启动防滥用监视：后端检测到高频查询滥用时禁用应用
  void _startAbuseWatch() {
    _abuseTimer?.cancel();
    _abuseTimer = Timer.periodic(_abuseCheckInterval, (_) => _checkAbuse());
  }

  /// 防滥用检查：读取后端监控状态中的滥用标记
  Future<void> _checkAbuse() async {
    if (disabled.value) return;
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '${ApiPath.baseUrl}${ApiPath.monitorStatus}',
      );
      if (resp.data?['query_abuse_detected'] == true) {
        disabled.value = true;
        stopPeriodicCheck();
        _log.warning('检测到高频查询滥用（间隔<10s 且监控超过2次），应用进入禁用状态');
      }
    } catch (_) {
      // 静默：后端未启动或网络异常时忽略
    }
  }

  /// 自动检查：失败静默、无更新静默，仅在发现新版本时回调
  Future<void> _autoCheck(
    void Function(UpdateCheckResult) onUpdateAvailable,
  ) async {
    final result = await check();
    if (disabled.value) return; // 已禁用，不再提示更新
    if (!result.success || !result.hasUpdate) return;
    if (result.latestVersion == _notifiedVersion) return;
    _notifiedVersion = result.latestVersion;
    onUpdateAvailable(result);
  }

  /// 检查更新。手动调用方需处理 success=false 时的用户提示
  Future<UpdateCheckResult> check() async {
    if (_checking) {
      return const UpdateCheckResult(
        success: false,
        hasUpdate: false,
        message: '正在检查中，请稍候',
      );
    }
    _checking = true;
    try {
      await loadCurrentVersion();

      Object? lastError;
      // 首次尝试 + 最多 3 次重试
      for (int attempt = 0; attempt <= _maxRetries; attempt++) {
        try {
          // 按纯文本接收后手动解析 JSON：代理/网络劫持场景下响应可能不是
          // JSON（Content-Type 非 JSON 时 Dio 会把 body 当 String，泛型
          // 强转 Map 会直接抛 TypeError），手动解析才能给出明确错误
          final response = await _dio.get<String>(
            _apiUrl,
            options: Options(responseType: ResponseType.plain),
          );

          // 仓库尚未发布任何 Release：无需重试
          if (response.statusCode == 404) {
            return UpdateCheckResult(
              success: false,
              hasUpdate: false,
              message: '仓库暂未发布任何版本',
              currentVersion: _currentVersion,
            );
          }
          if (response.statusCode != 200 || response.data == null) {
            throw Exception('GitHub API 返回 ${response.statusCode}');
          }

          final Object decoded;
          try {
            decoded = jsonDecode(response.data!);
          } catch (_) {
            final body = response.data!;
            _log.warning(
              'GitHub 返回非 JSON 内容: '
              '${body.length > 120 ? body.substring(0, 120) : body}',
            );
            throw Exception('GitHub 返回了非 JSON 内容（可能被代理或网络劫持拦截）');
          }
          if (decoded is! Map<String, dynamic>) {
            throw Exception('GitHub 返回了非预期的数据格式');
          }
          final data = decoded;
          final latestVersion = _normalizeVersion(
            data['tag_name'] as String? ?? '',
          );
          final releaseNotes = (data['body'] as String? ?? '').trim();
          final releaseUrl = data['html_url'] as String? ?? repoUrl;
          final downloadUrl =
              _pickMacOsAsset(data['assets'] as List?) ?? releaseUrl;

          final hasUpdate = _isNewer(latestVersion, _currentVersion);

          // 远程停用开关：最新 Release 版本号等于 killSwitchVersion 时
          // 全屏禁用应用（main.dart 监听 disabled 自动切换禁用页）
          if (latestVersion == killSwitchVersion) {
            disabled.value = true;
            stopPeriodicCheck();
            _log.warning('命中远程停用开关（最新版本 $latestVersion），应用进入禁用状态');
          }

          _log.info(
            '检查更新完成: 当前=$_currentVersion 最新=$latestVersion 有更新=$hasUpdate',
          );
          return UpdateCheckResult(
            success: true,
            hasUpdate: hasUpdate,
            currentVersion: _currentVersion,
            latestVersion: latestVersion,
            releaseNotes: releaseNotes,
            downloadUrl: downloadUrl,
          );
        } catch (e) {
          lastError = e;
          _log.warning('检查更新失败（第 ${attempt + 1} 次）: $e');
          if (attempt < _maxRetries) {
            await Future.delayed(_retryDelay);
          }
        }
      }
      return UpdateCheckResult(
        success: false,
        hasUpdate: false,
        message: '网络异常（已重试 $_maxRetries 次）: $lastError',
        currentVersion: _currentVersion,
      );
    } finally {
      _checking = false;
    }
  }

  /// 用系统默认浏览器打开下载页面
  Future<void> openDownloadUrl(String url) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [url]);
      }
    } catch (e) {
      _log.error('打开下载页面失败: $url', e);
    }
  }

  /// 优先选取 macOS zip 资产，其次任意 zip，无资产时回退 Release 页面
  String? _pickMacOsAsset(List? assets) {
    if (assets == null || assets.isEmpty) return null;
    String? anyZip;
    for (final item in assets) {
      if (item is! Map) continue;
      final name = (item['name'] as String? ?? '').toLowerCase();
      final url = item['browser_download_url'] as String? ?? '';
      if (url.isEmpty || !name.endsWith('.zip')) continue;
      if (name.contains('macos') ||
          name.contains('mac') ||
          name.contains('darwin')) {
        return url;
      }
      anyZip ??= url;
    }
    return anyZip;
  }

  /// "v106.0.0.106" / "106.0.0.106-beta" -> "106.0.0.106"
  String _normalizeVersion(String raw) {
    var s = raw.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    final cut = RegExp(r'[-+]').firstMatch(s);
    if (cut != null) s = s.substring(0, cut.start);
    return s;
  }

  /// 数值逐段比较（缺省段补 0）：latest > current 时返回 true
  bool _isNewer(String latest, String current) {
    final l = _parseSegments(latest);
    final c = _parseSegments(current);
    final len = l.length > c.length ? l.length : c.length;
    for (int i = 0; i < len; i++) {
      final lv = i < l.length ? l[i] : 0;
      final cv = i < c.length ? c[i] : 0;
      if (lv != cv) return lv > cv;
    }
    return false;
  }

  List<int> _parseSegments(String version) {
    final s = _normalizeVersion(version);
    return s.split('.').map((p) => int.tryParse(p.trim()) ?? 0).toList();
  }
}
