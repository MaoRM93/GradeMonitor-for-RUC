import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform, Process;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/constants/api_path.dart';
import '../../core/constants/api_token.dart';
import '../logger/app_logger.dart';
import 'update_verifier.dart';

/// GitHub Release 的安装包资源
class ReleaseAsset {
  /// 资源文件名（如 GradeMonitor-108.1.0.100-macOS.zip）
  final String name;

  /// 浏览器下载地址（browser_download_url）
  final String url;

  /// 文件大小（字节）
  final int size;

  /// GitHub 服务端计算的摘要（形如 `sha256:abc…`）；旧 Release 可能为空。
  ///
  /// 来自 Releases API 的 `digest` 字段，仅作辅助提示——真正的信任锚是
  /// 发布包签名清单（见 [UpdateVerifier]），因为 digest 与资产同源，
  /// 资产被替换时 digest 也会跟着被替换。
  final String digest;

  const ReleaseAsset({
    required this.name,
    required this.url,
    required this.size,
    this.digest = '',
  });

  /// 摘要的裸 hex 部分（无 `sha256:` 前缀），无法解析时为空
  String get digestHex {
    final d = digest.trim().toLowerCase();
    if (d.isEmpty) return '';
    final idx = d.indexOf(':');
    return idx >= 0 ? d.substring(idx + 1) : d;
  }
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

  /// 从 Release 正文解析出的本平台签名清单（可能多份）。
  ///
  /// 同一平台可能同时发布 `.zip`（应用内自动更新）与 `.dmg`（手动下载安装），
  /// 两者 sha256 不同，必须各持一块清单，由 [manifestFor] 按实际资产名挑。
  final List<SignedManifest> manifests;

  const UpdateCheckResult({
    required this.ok,
    this.hasUpdate = false,
    this.latestVersion = '',
    this.releaseNotes = '',
    this.assets = const [],
    this.error,
    this.manifests = const [],
  });

  /// 挑出与 [asset] 同名的那一份清单；没有则返回 null。
  ///
  /// 返回 null 意味着**无法校验**，安装时必须拒绝自动安装并降级为手动。
  SignedManifest? manifestFor(ReleaseAsset? asset) {
    if (asset == null) return null;
    return UpdateVerifier.selectForAsset(manifests, asset.name);
  }

  /// 本平台的第一份清单（仅用于「是否发布了清单」这类粗略判断）
  SignedManifest? get manifest => manifests.isEmpty ? null : manifests.first;
}

/// 提示的类别
enum NoticeKind {
  /// 停用页（红色）：114.514 / 114.513 存在时触发，确认后退出程序
  killSwitch,

  /// 开发者重要提醒页（蓝色）：114.515 存在时触发，确认后仅关闭页面
  developerNotice,

  /// 通知广播：114 号段里 513/514/515 之外的 tag（如 114.100），
  /// 只在程序右上角弹一张提示卡，正文纯文本展示，点「好」关闭。
  broadcast,
}

/// 一次被命中的 Release 提示记录（原文 body 交给 Markdown 渲染）
class ReleaseNotice {
  final NoticeKind kind;

  /// '114.514' / '114.513' / '114.515'
  final String tag;

  /// 预留标题（release name，可为空）
  final String title;

  /// release body，Markdown 原文
  final String body;

  const ReleaseNotice({
    required this.kind,
    required this.tag,
    this.title = '',
    required this.body,
  });
}

/// GitHub Release 更新与全局禁用服务
///
/// - 检查更新：GitHub Releases API（收纯文本后手动 jsonDecode），
///   超时 20 秒，失败后最多重试 3 次
/// - 远程停用开关：按 tag 精确请求 114.514 / 114.513，存在即全屏禁用应用
/// - 开发者提醒：按 tag 精确请求 114.515，存在即弹蓝色提醒页（不禁用）
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

  /// 停用开关（主）：GitHub Release 存在该 tag 时全屏禁用应用
  static const String killSwitchVersion = '114.514';

  /// 停用开关（备）：514 不存在时的次级停用 tag
  static const String killSwitchVersionFallback = '114.513';

  /// 开发者重要提醒页对应的 Release tag
  static const String developerNoticeVersion = '114.515';

  /// 通知广播号段：tag 的**首段**是 114（如 `114.100`）。
  ///
  /// 只认首段，末位是 114 的版本号（如 `108.1.0.114`）不属于号段，
  /// 仍按正常「检查更新」处理。
  static const String noticeSeriesPrefix = '114';

  /// 号段内已被专用页面占用的 tag，其余同类 tag 走右上角提示
  static const List<String> reservedNoticeTags = [
    killSwitchVersion,
    killSwitchVersionFallback,
    developerNoticeVersion,
  ];

  /// Release 列表（含全部 tag 与 body），用于在 114 号段里找当前广播条目
  static const String _releasesListApi =
      'https://api.github.com/repos/$repoOwner/$repoName/releases?per_page=50';

  /// 按 tag 精确取单个 Release 的 API 前缀
  ///
  /// 不用 `/releases/latest`：latest 只能看到最新一条，无法区分
  /// 「tag 被删除」与「tag 存在但 body 为空」，也看不到非最新 tag。
  static const String _releaseByTagApiPrefix =
      'https://api.github.com/repos/$repoOwner/$repoName/releases/tags/';

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

  /// 本进程内是否由 Release 停用开关拉起了禁用态
  /// （区分「Release 停用」与「滥用停用」，避免清除时误解除滥用禁用）
  bool _killSwitchActive = false;

  /// 已在本进程内被用户关闭过的开发者提醒 tag（不落盘：下次启动重新判定）
  final Set<String> _dismissedDeveloperTags = {};

  /// 已在本进程内被用户关闭过的广播 tag（不落盘：下次启动重新判定）
  final Set<String> _dismissedBroadcastTags = {};

  /// 上一次**明确**判定出的停用 tag（null = 明确无停用）。
  ///
  /// 用于网络抖动时保守沿用：探测结果为「未知」时不改动界面。
  String? _lastKillTag;

  /// checkReleaseNotices 并发保护（启动与每小时定时器可能撞车）
  Future<void>? _noticeInFlight;

  /// 全局禁用状态（static）：main.dart 监听后自动切换到禁用页
  static final ValueNotifier<bool> disabled = ValueNotifier<bool>(false);

  /// 当前应展示的全屏 Release 提示（null = 正常显示 App）
  ///
  /// - [NoticeKind.killSwitch]：停用页（红色，确认后退出程序）
  /// - [NoticeKind.developerNotice]：开发者提醒页（蓝色，确认后仅关闭）
  ///
  /// 与 [disabled] 分工：[disabled] 表示「App 被停用」，可由停用页、
  /// 客户端防滥用或后端滥用标记置真；本 notifier 只承载页面要渲染的
  /// Release 正文，停用页从它取 body。
  static final ValueNotifier<ReleaseNotice?> releaseNotice =
      ValueNotifier<ReleaseNotice?>(null);

  /// 自动检查（启动/每小时）发现新版本时的广播：主壳监听后弹出更新弹窗。
  /// 手动检查不写入（设置页自己处理 UI）。
  static final ValueNotifier<UpdateCheckResult?> updateFound =
      ValueNotifier<UpdateCheckResult?>(null);

  /// 预发行版本告警广播：当前版本 **高于** GitHub 最新 Release 时触发
  /// （即用户装的是开发者尚未正式发布的预览副本）。主壳监听后弹红色提示框。
  static final ValueNotifier<UpdateCheckResult?> preReleaseFound =
      ValueNotifier<UpdateCheckResult?>(null);

  /// 右上角通知广播（114 号段里除 513/514/515 之外的 tag）。
  ///
  /// null = 没有待展示的广播。主壳把它渲染成右上角的小提示卡，
  /// 点「好」调用 [dismissBroadcast] 关闭。
  static final ValueNotifier<ReleaseNotice?> broadcastNotice =
      ValueNotifier<ReleaseNotice?>(null);

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

    // Release 提示检查（停用页 / 开发者提醒）独立于 checkForUpdate 运行：
    // 即使检查更新因网络失败抛错，这里的结果依然能驱动界面。
    unawaited(checkReleaseNotices());

    // 之后每小时静默检查一次
    _updateTimer?.cancel();
    _updateTimer = Timer.periodic(const Duration(hours: 1), (_) {
      unawaited(checkForUpdate(silent: true));
      unawaited(checkReleaseNotices());
    });

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
      final token = ApiToken.value;
      final resp = await _dio.get<Map<String, dynamic>>(
        '${ApiPath.baseUrl}${ApiPath.monitorStatus}',
        options: token.isEmpty
            ? null
            : Options(headers: {ApiToken.headerName: token}),
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
            return const UpdateCheckResult(ok: false, error: '仓库暂未发布任何版本');
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
                    digest: (raw['digest'] ?? '').toString(),
                  ),
          ];

          // 解析发布包签名清单（若发布者附带）。解析失败不阻断检查更新，
          // 但会导致后续安装时无法校验 → 自动安装被拒绝。
          // 同平台可能同时发布 zip 与 dmg，故收全部清单，安装时按资产名精确匹配。
          final manifests = UpdateVerifier.parseManifests(releaseNotes);
          if (manifests.isEmpty) {
            _log.warning('该 Release 未附带本平台签名清单，自动安装将被拒绝');
          }

          // 远程停用开关：统一交给 [checkReleaseNotices] 按 tag 精确判定，
          // 这里不再自己比 tag，避免同一 tag 两套判断互相打架。
          if (isKillSwitchTag(tag)) {
            await checkReleaseNotices();
            if (disabled.value) {
              _log.warning('命中远程停用开关（$tag），应用进入禁用状态');
              return const UpdateCheckResult(ok: false, error: '当前版本已被停用');
            }
            return UpdateCheckResult(ok: true, latestVersion: latestVersion);
          }

          // 114 号段是「通知广播」专用通道（513/514/515 走全屏页，其余走上
          // 右上角提示卡）。这类 tag 绝不参与版本比较：既不弹更新弹窗，
          // 也不弹预发行告警，避免一条通知把所有人的更新提示顶掉。
          // 判定只认首段，`108.1.0.114` 这类末位 114 仍照常检查更新。
          if (isNoticeSeriesTag(tag)) {
            _log.info('Release $tag 属于通知号段，跳过版本比较');
            unawaited(checkReleaseNotices());
            return UpdateCheckResult(
              ok: true,
              latestVersion: latestVersion,
              releaseNotes: releaseNotes,
              assets: assets,
              manifests: manifests,
            );
          }

          final hasUpdate = _isNewer(latestVersion, _currentVersion);
          // 反向比较：当前版本比最新正式版还新 → 预发行（预览）副本
          final isPreRelease = _isNewer(_currentVersion, latestVersion);
          final result = UpdateCheckResult(
            ok: true,
            hasUpdate: hasUpdate,
            latestVersion: latestVersion,
            releaseNotes: releaseNotes,
            assets: assets,
            manifests: manifests,
          );
          if (hasUpdate) {
            _log.info('发现新版本: $latestVersion（当前 $_currentVersion）');
            if (silent) updateFound.value = result;
          } else if (isPreRelease) {
            _log.info(
              '当前版本 $_currentVersion 高于最新 Release $latestVersion，'
              '判定为预发行版本',
            );
            if (silent) preReleaseFound.value = result;
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

  // ---- Release 提示（停用页 / 开发者提醒）----

  /// 是否为停用类 tag
  static bool isKillSwitchTag(String tag) {
    final t = tag.trim();
    return t == killSwitchVersion || t == killSwitchVersionFallback;
  }

  /// 是否属于通知广播号段（首段为 114，如 `114.100`）。
  ///
  /// 判定只看**首段**：`108.1.0.114` 的 114 在末位，不属于号段，
  /// 仍需照常当作版本号参与检查更新。
  static bool isNoticeSeriesTag(String tag) {
    final t = tag.trim().replaceFirst(RegExp(r'^[vV]'), '');
    if (t.isEmpty) return false;
    final head = t.split('.').first;
    return head == noticeSeriesPrefix;
  }

  /// 号段内但未被专用页面占用的 tag（走右上角提示卡）
  static bool isBroadcastTag(String tag) {
    final t = tag.trim();
    if (!isNoticeSeriesTag(t)) return false;
    return !reservedNoticeTags.contains(t);
  }

  /// 关闭开发者提醒页：仅清空提示状态，回到 AppNavigation，不退出软件。
  ///
  /// [disabled] 保持 false —— 提醒页从不让 App 进入禁用态。
  static void dismissDeveloperNotice() {
    final notice = releaseNotice.value;
    if (notice == null || notice.kind != NoticeKind.developerNotice) return;
    _instance._dismissedDeveloperTags.add(notice.tag);
    releaseNotice.value = null;
    _instance._log.info('开发者提醒已关闭: ${notice.tag}');
  }

  /// 关闭右上角通知广播卡片（仅清 UI 状态，不落盘：下次启动重新判定）
  static void dismissBroadcast() {
    final notice = broadcastNotice.value;
    if (notice == null) return;
    _instance._dismissedBroadcastTags.add(notice.tag);
    broadcastNotice.value = null;
    _instance._log.info('通知广播已关闭: ${notice.tag}');
  }

  /// 清除停用态（开发者后门 / 外部调用）：同时复位 disabled 与提示记录。
  ///
  /// 这是人为的应急出口，故**强制**回到可用状态（与旧后门行为一致）；
  /// 自动流程不使用它 —— 自动解除只走 [_clearKillSwitch]，不会误解除滥用禁用。
  static void clearKillSwitchNotice() {
    final service = _instance;
    final notice = releaseNotice.value;
    if (notice != null && notice.kind == NoticeKind.killSwitch) {
      releaseNotice.value = null;
    }
    service._killSwitchActive = false;
    disabled.value = false;
    service._log.info('停用态已被手动清除');
  }

  /// 逐个 tag 请求 `/releases/tags/<tag>`，据此决定是否展示提示页。
  ///
  /// 删除语义：
  /// - **404** → 该 tag 已被删除（确定结果），本次启动不再因它弹任何东西
  /// - **200** → 存在，body 可为空（空则页面用兜底文案）
  /// - 其他错误（限流 403 / 超时 / 被劫持）→ 未知，**保守处理**：
  ///   不认定删除，也不改变上次已确定的界面状态，避免网络抖动闪红屏
  ///
  /// 本方法不落盘任何「已禁用」状态，每次启动都实时判定，删除即恢复正常。
  Future<void> checkReleaseNotices() {
    // 串行化：启动与每小时定时器可能同时触发，复用同一个在途请求
    final inFlight = _noticeInFlight;
    if (inFlight != null) return inFlight;
    final future = _runReleaseNoticeCheck();
    _noticeInFlight = future;
    return future.whenComplete(() => _noticeInFlight = null);
  }

  Future<void> _runReleaseNoticeCheck() async {
    try {
      final probes = await Future.wait([
        _probeReleaseTag(killSwitchVersion),
        _probeReleaseTag(killSwitchVersionFallback),
        _probeReleaseTag(developerNoticeVersion),
      ]);
      final primary = probes[0];
      final fallback = probes[1];
      final developer = probes[2];

      // 1) 停用判定：514 优先；514 明确删除时回落到 513；
      //    任一探测为「未知」则沿用上一次已确定的 tag，不动界面。
      final String? desired;
      if (primary.exists == true) {
        desired = killSwitchVersion;
      } else if (primary.exists == false) {
        if (fallback.exists == true) {
          desired = killSwitchVersionFallback;
        } else if (fallback.exists == false) {
          desired = null; // 两个 tag 都不存在 → 不弹禁用页，正常启动
        } else {
          desired = _lastKillTag; // 513 未知：保留上次已知状态
        }
      } else {
        desired = _lastKillTag; // 514 未知：保留上次已知状态
      }

      _lastKillTag = desired;
      if (desired == null) {
        _clearKillSwitch();
      } else if (desired == killSwitchVersion && primary.exists == true) {
        _applyKillSwitch(killSwitchVersion, primary);
      } else if (desired == killSwitchVersionFallback &&
          fallback.exists == true) {
        _applyKillSwitch(killSwitchVersionFallback, fallback);
      }
      // desired 非空但本次没拿到该 tag 的 body：上次已渲染的内容保持不变

      // 2) 开发者提醒判定（独立于停用）：禁用态优先，提醒页不覆盖禁用页
      if (disabled.value) return;
      if (developer.exists == true) {
        if (_dismissedDeveloperTags.contains(developerNoticeVersion)) return;
        _applyDeveloperNotice(developerNoticeVersion, developer);
      } else if (developer.exists == false) {
        // tag 已删除：撤下提醒页，并清掉关闭记录（下次若重建则重新提醒）
        _dismissedDeveloperTags.remove(developerNoticeVersion);
        final current = releaseNotice.value;
        if (current != null &&
            current.kind == NoticeKind.developerNotice &&
            current.tag == developerNoticeVersion) {
          releaseNotice.value = null;
        }
      }

      // 3) 广播通知（114 号段里除 513/514/515 之外的 tag）：右上角提示卡
      await _checkBroadcast();
    } catch (e) {
      // 任何异常都不改界面：宁可这次不弹，也不误弹/误清
      _log.warning('Release 提示检查异常（保持原状态）: $e');
    }
  }

  /// 在 114 号段里找一条待广播的 Release（最新的一条），展示到右上角。
  ///
  /// 用列表接口一次取回全部 Release：号段 tag 是按需新增/删除的，
  /// 没有固定名称可逐个探测。列表为空或网络异常时**不动**界面，
  /// 已展示的卡片不会被莫名其妙撤掉。
  Future<void> _checkBroadcast() async {
    try {
      final response = await _dio.get<String>(
        _releasesListApi,
        options: Options(responseType: ResponseType.plain),
      );
      if (response.statusCode != 200 || response.data == null) return;
      final Object? decoded;
      try {
        decoded = jsonDecode(response.data!);
      } catch (_) {
        return;
      }
      if (decoded is! List) return;

      _TagProbe? hit;
      String? hitTag;
      for (final raw in decoded) {
        if (raw is! Map<String, dynamic>) continue;
        final tag = _normalizeVersion((raw['tag_name'] ?? '').toString());
        if (!isBroadcastTag(tag)) continue;
        hitTag = tag;
        hit = _TagProbe(
          exists: true,
          title: (raw['name'] ?? '').toString().trim(),
          body: (raw['body'] ?? '').toString().trim(),
        );
        // 列表按发布时间倒序，第一条命中即最新
        break;
      }

      if (hitTag == null || hit == null) {
        // 号段里没有任何广播条目：撤下卡片，并清掉本次进程的关闭记录
        _dismissedBroadcastTags.clear();
        final current = broadcastNotice.value;
        if (current != null && current.kind == NoticeKind.broadcast) {
          broadcastNotice.value = null;
        }
        return;
      }
      if (_dismissedBroadcastTags.contains(hitTag)) return;
      if (disabled.value) return;
      final current = broadcastNotice.value;
      final same =
          current != null &&
          current.kind == NoticeKind.broadcast &&
          current.tag == hitTag &&
          current.body == hit.body;
      if (same) return;
      broadcastNotice.value = ReleaseNotice(
        kind: NoticeKind.broadcast,
        tag: hitTag,
        title: hit.title,
        body: hit.body,
      );
      _log.info('命中通知广播（$hitTag）');
    } catch (e) {
      _log.warning('广播通知检查失败（保持原状态）: $e');
    }
  }

  /// 请求单个 tag 的 Release。404 才算「已删除」，其余错误一律 unknown。
  Future<_TagProbe> _probeReleaseTag(String tag) async {
    try {
      final response = await _dio.get<String>(
        '$_releaseByTagApiPrefix$tag',
        options: Options(responseType: ResponseType.plain),
      );
      final status = response.statusCode;
      if (status == 404) {
        // 明确的删除信号
        return const _TagProbe(exists: false);
      }
      if (status == 403) {
        // 限流 / 需要认证：不是删除
        _log.warning('Release $tag 查询被限流（403），保持原状态');
        return const _TagProbe(exists: null);
      }
      if (status != 200 || response.data == null) {
        _log.warning('Release $tag 查询返回 $status，保持原状态');
        return const _TagProbe(exists: null);
      }
      final Object decoded;
      try {
        decoded = jsonDecode(response.data!);
      } catch (_) {
        _log.warning('Release $tag 返回非 JSON 内容，保持原状态');
        return const _TagProbe(exists: null);
      }
      if (decoded is! Map<String, dynamic>) {
        return const _TagProbe(exists: null);
      }
      return _TagProbe(
        exists: true,
        title: (decoded['name'] ?? '').toString().trim(),
        body: (decoded['body'] ?? '').toString().trim(),
      );
    } catch (e) {
      // 超时 / 连接失败 / 5xx：无法判定，绝不当作删除
      _log.warning('Release $tag 查询失败（保持原状态）: $e');
      return const _TagProbe(exists: null);
    }
  }

  void _applyKillSwitch(String tag, _TagProbe probe) {
    _killSwitchActive = true;
    final current = releaseNotice.value;
    final same =
        current != null &&
        current.kind == NoticeKind.killSwitch &&
        current.tag == tag &&
        current.body == probe.body;
    if (!same) {
      releaseNotice.value = ReleaseNotice(
        kind: NoticeKind.killSwitch,
        tag: tag,
        title: probe.title,
        body: probe.body,
      );
      _log.warning('命中远程停用开关（$tag），应用进入禁用状态');
    }
    if (!disabled.value) disabled.value = true;
  }

  void _clearKillSwitch() {
    final current = releaseNotice.value;
    if (current != null && current.kind == NoticeKind.killSwitch) {
      releaseNotice.value = null;
    }
    if (!_killSwitchActive) return;
    _killSwitchActive = false;
    // 滥用类禁用与停用 tag 无关：tag 被删除时不能顺手把它解除
    if (_abuseTriggered) return;
    disabled.value = false;
    _log.info('停用 tag 均已删除，恢复正常启动');
  }

  void _applyDeveloperNotice(String tag, _TagProbe probe) {
    if (disabled.value) return;
    final current = releaseNotice.value;
    final same =
        current != null &&
        current.kind == NoticeKind.developerNotice &&
        current.tag == tag &&
        current.body == probe.body;
    if (same) return;
    releaseNotice.value = ReleaseNotice(
      kind: NoticeKind.developerNotice,
      tag: tag,
      title: probe.title,
      body: probe.body,
    );
    _log.info('命中开发者提醒 Release（$tag）');
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
  /// mac → 名称含 "mac" 且是 zip（自动安装靠 ditto 解 zip，dmg 解不了）
  /// windows → 含 "windows"（优先 x64）
  ///
  /// 出现多种 mac 资源时（例如同时发布 .zip 给自动更新、.dmg 给手动分发），
  /// 必须优先选 .zip：两者名字都含 "mac"，按数组顺序取第一个会随机拿到 dmg，
  /// 导致安装阶段 ditto 解包失败。这里显式排除 dmg/pkg，只认 zip。
  ReleaseAsset? pickPlatformAsset(List<ReleaseAsset> assets) {
    if (assets.isEmpty) return null;
    final bool isMac = Platform.isMacOS;
    final bool isWin = Platform.isWindows;
    ReleaseAsset? fallback;
    for (final a in assets) {
      final n = a.name.toLowerCase();
      if (isMac) {
        if (n.contains('mac')) {
          // 自动更新只接受 zip；dmg/pkg 留作手动安装
          if (n.endsWith('.zip')) return a;
          fallback ??= a;
        }
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

  String _join(String dir, String name) => '$dir${Platform.pathSeparator}$name';

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

/// 单个 tag 的探测结果
///
/// [exists] 三态：
/// - true  → Release 存在（body 可能为空字符串）
/// - false → 明确的 404，Release 已被删除
/// - null  → 网络/限流/解析异常，**未知**，不得据此改动界面
class _TagProbe {
  final bool? exists;
  final String title;
  final String body;

  const _TagProbe({required this.exists, this.title = '', this.body = ''});
}
