import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform, Process;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/constants/api_path.dart';
import '../logger/app_logger.dart';

/// GitHub Release 的安装包资源
class ReleaseAsset {
  /// 资源文件名（如 GradeMonitor-108.1.0.100-macOS.zip）
  final String name;

  /// 浏览器下载地址（browser_download_url）
  final String url;

  /// 文件大小（字节）
  final int size;

  const ReleaseAsset({required this.name, required this.url, required this.size});
}

/// 检查更新结果
class UpdateCheckResult {
  /// 请求与解析是否成功（失败时 [error] 说明原因）
  final bool ok;

  /// 是否存在新版本
  final bool hasUpdate;

  /// 最新版本号（去除 tag 前缀 v 及后缀）
  final String latestVersion;

  /// 更新说明（release body）
  final String releaseNotes;

  /// 该 Release 附带的安装包资源列表
  final List<ReleaseAsset> assets;

  /// 失败原因（手动检查时提示用户）
  final String? error;

  const UpdateCheckResult({
    required this.ok,
    this.hasUpdate = false,
    this.latestVersion = '',
    this.releaseNotes = '',
    this.assets = const [],
    this.error,
  });
}

/// GitHub Release 更新与全局禁用服务
///
/// - 检查更新：GitHub Releases API（收纯文本后手动 jsonDecode），
///   超时 20 秒，失败后最多重试 3 次
/// - 远程停用开关：最新 Release tag 等于 [killSwitchVersion] 时全屏禁用应用
/// - 防滥用检测（双通道）：
///   · 客户端滑动窗口：60 秒内查询超过阈值主动禁用
///   · 后端标记轮询：读取后端监控状态中的滥用标记
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

  // ---- 常量 ----

  static const String repoOwner = 'MaoRM93';
  static const String repoName = 'GradeMonitor-for-RUC';
  static const String repoUrl = 'https://github.com/$repoOwner/$repoName';

  /// 检查更新 API 地址（最新正式 release，不含 draft / pre-release）
  ///
  /// 注意：必须是 api.github.com 的 API 地址。
  /// 不能用 repoUrl/releases/latest 网页地址——那返回的是 HTML 页面，
  /// 会一直报“GitHub 返回了非 JSON 内容”。
  static const String _latestReleaseApi =
      'https://api.github.com/repos/$repoOwner/$repoName/releases/latest';

  /// 停用开关：GitHub 最新 Release 的 tag 等于此值时全屏禁用应用
  static const String killSwitchVersion = '114.514';

  /// 发行状态：'Release' 正式版 / 'Beta' 测试版（主页左下角展示，发布时手动更新）
  // ignore: constant_identifier_names
  static const String VerStatus = 'Release';

  static const Duration _timeout = Duration(seconds: 20);
  static const int _maxRetries = 3;
  static const Duration _retryDelay = Duration(seconds: 2);

  /// 后端滥用标记轮询周期：低频读取后端监控状态（开销可忽略）
  static const Duration _abuseCheckInterval = Duration(seconds: 30);

  /// 防滥用滑动窗口：60 秒内查询次数超过阈值即禁用
  static const int _abuseWindowMs = 60000;
  static const int _abuseThreshold = 40;

  // ---- 运行时状态 ----

  final _log = AppLogger('update');
  late final Dio _dio;
  Timer? _abuseTimer;
  Timer? _updateTimer;
  bool _checking = false;

  /// 防滥用滑动窗口
  final List<int> _queryTimestamps = [];
  bool _abuseTriggered = false;

  /// 全局禁用状态（static）：main.dart 监听后自动切换到禁用页
  static final ValueNotifier<bool> disabled = ValueNotifier<bool>(false);

  /// 自动检查（启动/每小时）发现新版本时的广播：主壳监听后弹出更新弹窗。
  /// 手动检查不写入（设置页自己处理 UI）。
  static final ValueNotifier<UpdateCheckResult?> updateFound =
      ValueNotifier<UpdateCheckResult?>(null);

  /// 运行时完整版本号（如 108.1.0.100），未加载完成时为空字符串
  String _currentVersion = '';
  String get currentVersion => _currentVersion;

  /// 初始化：读取完整版本号 + 静默检查远程停用开关（不弹任何 UI）
  /// + 启动后端滥用标记轮询
  Future<void> init() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final build = info.buildNumber.trim();
      _currentVersion = build.isEmpty ? info.version : '${info.version}.$build';
      _log.info('当前应用版本: $_currentVersion');
    } catch (e) {
      _log.warning('读取应用版本失败: $e');
    }

    // 静默检查：开启程序时检查一次（发现更新时经 updateFound 广播弹窗）
    unawaited(checkForUpdate(silent: true));

    // 之后每小时静默检查一次
    _updateTimer?.cancel();
    _updateTimer = Timer.periodic(
      const Duration(hours: 1),
      (_) => unawaited(checkForUpdate(silent: true)),
    );

    // 后端滥用标记轮询
    _abuseTimer?.cancel();
    _abuseTimer = Timer.periodic(_abuseCheckInterval, (_) => _checkAbuse());
  }

  /// 上报一次成绩查询（供客户端防滥用滑动窗口统计）
  void reportQuery() {
    if (disabled.value || _abuseTriggered) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _queryTimestamps.add(now);
    while (_queryTimestamps.isNotEmpty &&
        now - _queryTimestamps.first > _abuseWindowMs) {
      _queryTimestamps.removeAt(0);
    }
    if (_queryTimestamps.length > _abuseThreshold) {
      _abuseTriggered = true;
      _log.warning('防滥用命中：60 秒内 ${_queryTimestamps.length} 次查询，禁用程序');
      disabled.value = true;
    }
  }

  /// 后端滥用标记轮询：读取后端监控状态中的滥用标记
  Future<void> _checkAbuse() async {
    if (disabled.value) return;
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '${ApiPath.baseUrl}${ApiPath.monitorStatus}',
      );
      if (resp.data?['query_abuse_detected'] == true) {
        disabled.value = true;
        _log.warning('后端检测到高频查询滥用，应用进入禁用状态');
      }
    } catch (_) {
      // 静默：后端未启动或网络异常时忽略
    }
  }

  /// 检查更新。手动调用方需处理 ok=false 时的用户提示。
  /// [silent] 为 true 时不打日志（启动时的静默检查）。
  Future<UpdateCheckResult> checkForUpdate({bool silent = false}) async {
    if (_checking) {
      return const UpdateCheckResult(ok: false, error: '正在检查中，请稍候');
    }
    _checking = true;
    try {
      if (_currentVersion.isEmpty) {
        try {
          final info = await PackageInfo.fromPlatform();
          final build = info.buildNumber.trim();
          _currentVersion = build.isEmpty
              ? info.version
              : '${info.version}.$build';
        } catch (_) {}
      }

      Object? lastError;
      // 首次尝试 + 最多 3 次重试
      for (int attempt = 0; attempt <= _maxRetries; attempt++) {
        try {
          // 按纯文本接收后手动解析 JSON：代理/网络劫持场景下响应可能不是
          // JSON（Content-Type 非 JSON 时 Dio 会把 body 当 String，泛型
          // 强转 Map 会直接抛 TypeError），手动解析才能给出明确错误
          final response = await _dio.get<String>(
            _latestReleaseApi,
            options: Options(responseType: ResponseType.plain),
          );

          // 仓库尚未发布任何 Release：无需重试
          if (response.statusCode == 404) {
            return const UpdateCheckResult(
              ok: false,
              error: '仓库暂未发布任何版本',
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

          final tag = data['tag_name'] as String? ?? '';
          if (tag.isEmpty) {
            return const UpdateCheckResult(ok: false, error: '未获取到版本号');
          }
          final latestVersion = _normalizeVersion(tag);
          final releaseNotes = (data['body'] as String? ?? '').trim();
          final assets = <ReleaseAsset>[
            for (final raw in (data['assets'] as List<Object?>? ?? const []))
              if (raw is Map<String, dynamic>)
                if ((raw['browser_download_url'] ?? '').toString().isNotEmpty)
                  ReleaseAsset(
                    name: (raw['name'] ?? '').toString(),
                    url: (raw['browser_download_url'] ?? '').toString(),
                    size: (raw['size'] is int) ? raw['size'] as int : 0,
                  ),
          ];

          // 远程停用开关：最新 Release tag 等于 killSwitchVersion 时
          // 全屏禁用应用（main.dart 监听 disabled 自动切换禁用页）
          if (latestVersion == killSwitchVersion) {
            _log.warning('命中远程停用开关（最新版本 $latestVersion），应用进入禁用状态');
            disabled.value = true;
            return const UpdateCheckResult(ok: false, error: '当前版本已被停用');
          }

          final hasUpdate = _isNewer(latestVersion, _currentVersion);
          final result = UpdateCheckResult(
            ok: true,
            hasUpdate: hasUpdate,
            latestVersion: latestVersion,
            releaseNotes: releaseNotes,
            assets: assets,
          );
          if (hasUpdate) {
            _log.info('发现新版本: $latestVersion（当前 $_currentVersion）');
            if (silent) updateFound.value = result;
          }
          return result;
        } catch (e) {
          lastError = e;
          if (!silent) _log.warning('检查更新失败（第 ${attempt + 1} 次）: $e');
          if (attempt < _maxRetries) {
            await Future.delayed(_retryDelay);
          }
        }
      }
      return UpdateCheckResult(
        ok: false,
        error: '网络异常（已重试 $_maxRetries 次）: $lastError',
      );
    } finally {
      _checking = false;
    }
  }

  /// 用系统默认浏览器打开链接
  Future<void> openInBrowser([String? url]) async {
    final target = url ?? repoUrl;
    try {
      if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', target]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [target]);
      } else {
        await Process.run('xdg-open', [target]);
      }
    } catch (e) {
      _log.warning('打开链接失败: $e');
    }
  }

  // ---- 应用内直接下载 ----

  /// 按当前平台从 Release 资源中挑选合适的安装包；找不到返回 null。
  ///
  /// mac → 名称含 "mac";  windows → 含 "windows"（优先 x64）
  ReleaseAsset? pickPlatformAsset(List<ReleaseAsset> assets) {
    if (assets.isEmpty) return null;
    final bool isMac = Platform.isMacOS;
    final bool isWin = Platform.isWindows;
    ReleaseAsset? fallback;
    for (final a in assets) {
      final n = a.name.toLowerCase();
      if (isMac) {
        if (n.contains('mac')) return a;
      } else if (isWin) {
        if (n.contains('windows')) {
          if (n.contains('x64')) return a;
          fallback ??= a;
        }
      }
    }
    return fallback;
  }

  /// 用户「下载」文件夹路径
  String _downloadsDir() {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null || home.isEmpty) {
      return Directory.systemTemp.path;
    }
    final sep = Platform.pathSeparator;
    return '$home${sep}Downloads';
  }

  /// 直接下载安装包到「下载」文件夹（不跳浏览器）。
  ///
  /// - 独立下载用 Dio 实例：不继承检查更新的 20 秒超时（大文件会超时中断）
  /// - 下载过程中写入 `*.part` 临时文件，成功后原子重命名，避免半截文件
  /// - 目标同名文件已存在时按 `文件名 (2).zip` 顺延，不覆盖旧下载
  /// - 回调 [onProgress] 上报 (已接收字节, 总字节)；总大小未知时 total ≤ 0
  Future<String> downloadRelease(
    ReleaseAsset asset, {
    void Function(int received, int total)? onProgress,
  }) async {
    final dirPath = _downloadsDir();
    final dir = Directory(dirPath);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    // 从 URL 推导文件名，异常时用时间戳兜底
    String name;
    try {
      final segments = Uri.parse(asset.url).pathSegments;
      name = segments.isNotEmpty ? segments.last : '';
    } catch (_) {
      name = '';
    }
    if (name.trim().isEmpty || name.contains('/')) {
      final ts = DateTime.now().millisecondsSinceEpoch;
      name = 'GradeMonitor-update-$ts.zip';
    }

    // 同名顺延，避免覆盖
    String targetPath = _join(dirPath, name);
    if (File(targetPath).existsSync()) {
      final dot = name.lastIndexOf('.');
      final stem = dot > 0 ? name.substring(0, dot) : name;
      final ext = dot > 0 ? name.substring(dot) : '';
      for (int i = 2; i < 100; i++) {
        final candidate = _join(dirPath, '$stem ($i)$ext');
        if (!File(candidate).existsSync()) {
          targetPath = candidate;
          break;
        }
      }
    }

    // 临时文件：下载完成后改为正式名
    final tmpPath = '$targetPath.part';
    final tmpFile = File(tmpPath);

    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        headers: {'User-Agent': 'GradeMonitor-UpdateDownload'},
        followRedirects: true,
        validateStatus: (status) => status != null && status < 400,
      ),
    );
    try {
      await dio.download(
        asset.url,
        tmpPath,
        onReceiveProgress: onProgress,
        options: Options(responseType: ResponseType.bytes),
      );
      final tmp = File(tmpPath);
      if (!tmp.existsSync()) {
        throw Exception('下载未完成（临时文件丢失）');
      }
      tmp.renameSync(targetPath);
      _log.info('更新包已下载: $targetPath');
      return targetPath;
    } catch (e) {
      if (tmpFile.existsSync()) {
        try {
          tmpFile.deleteSync();
        } catch (_) {}
      }
      _log.warning('下载更新包失败: $e');
      rethrow;
    } finally {
      dio.close();
    }
  }

  String _join(String dir, String name) =>
      '$dir${Platform.pathSeparator}$name';

  /// 在系统文件管理器中显示已下载的文件 / 文件夹
  Future<void> revealInFileManager(String path) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else if (Platform.isWindows) {
        // Windows: 打开所在文件夹（explorer /select 对含空格参数不可靠）
        final dir = Directory(path).existsSync()
            ? path
            : path.substring(0, path.lastIndexOf('\\') + 1);
        await Process.run('explorer', <String>[dir]);
      } else {
        await Process.run('xdg-open', <String>[path]);
      }
    } catch (e) {
      _log.warning('打开文件夹失败: $e');
    }
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
    if (current.isEmpty || latest.isEmpty) return false;
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
