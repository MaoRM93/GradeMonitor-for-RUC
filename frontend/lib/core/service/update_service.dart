import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, HttpClient, Platform, Process;

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/constants/api_path.dart';
import '../../core/constants/api_token.dart';
import '../logger/app_logger.dart';
import 'feature_gate_service.dart';
import 'ui_prefs_service.dart';
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
  /// 停用页（红色）：正式远程控制 Release 存在时触发，确认后退出程序
  killSwitch,

  /// 开发者重要提醒页（蓝色）：正式远程控制 Release 存在时触发，确认后仅关闭页面
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

  /// 停用开关（主）：GitHub Release 存在该 tag 时全屏禁用应用
  static const String killSwitchVersion = 'service-suspension';

  /// 停用开关（备）：514 不存在时的次级停用 tag
  static const String killSwitchVersionFallback = 'service-suspension-fallback';

  /// 开发者重要提醒页对应的 Release tag
  static const String developerNoticeVersion = 'developer-alert';

  /// 通知广播号段：tag 的**首段**是 114（如 `114.100`）。
  ///
  /// 只认首段，末位是 114 的版本号（如 `108.1.0.114`）不属于号段，
  /// 仍按正常「检查更新」处理。
  static const String noticeSeriesPrefix = '114';

  /// 仅控制旧 114 普通广播；蓝屏/红屏保留独立探测与显示能力。
  static const bool enableLegacy114BroadcastNotices = true;
  static const String legacyBroadcastDisableVersion = '114.512';

  /// 远程功能开关（Flag-1xxx）指令频道：`control-v<rev>`。
  ///
  /// 这类 tag 的正文里是 Ed25519 签名的开关块，由后端 `remote_gates.py` 拉取
  /// 并验签应用，前端完全不参与解析。这里只需要把它**排除出版本比较**——
  /// 否则控制配置可能被误当成新版本，给所有用户弹
  /// 一个装不上的"发现新版本"。
  static const String gateConfigPrefix = 'control-v';

  /// 号段内已被专用页面占用的 tag，其余同类 tag 走右上角提示
  static const List<String> reservedNoticeTags = [
    killSwitchVersion,
    killSwitchVersionFallback,
    developerNoticeVersion,
    legacyBroadcastDisableVersion,
  ];

  /// 全部远程能力共享同一份 Release 列表缓存：更新、红/蓝屏、广播都不能各自
  /// 再发请求，否则反复启动很容易耗尽 GitHub 匿名 API 限额。
  static const String _releasesListApi =
      'https://api.github.com/repos/$repoOwner/$repoName/releases?per_page=100';

  /// 发行状态：'Release' 正式版 / 'Beta' 测试版（主页左下角展示，发布时手动更新）
  // ignore: constant_identifier_names
  static const String VerStatus = 'Release';

  static const Duration _timeout = Duration(seconds: 20);
  static const int _maxRetries = 3;
  static const Duration _retryDelay = Duration(seconds: 2);
  static const Duration _releaseCacheTtl = Duration(minutes: 5);

  List<Map<String, dynamic>>? _releaseCache;
  DateTime? _releaseCacheAt;
  Future<List<Map<String, dynamic>>?>? _releaseListInFlight;

  Future<List<Map<String, dynamic>>?> _fetchReleaseList({bool force = false}) {
    final cached = _releaseCache;
    final fetchedAt = _releaseCacheAt;
    if (!force &&
        cached != null &&
        fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < _releaseCacheTtl) {
      return Future<List<Map<String, dynamic>>?>.value(cached);
    }
    final running = _releaseListInFlight;
    if (running != null) return running;
    final future = _loadReleaseList();
    _releaseListInFlight = future;
    return future.whenComplete(() => _releaseListInFlight = null);
  }

  Future<List<Map<String, dynamic>>?> _loadReleaseList() async {
    try {
      final response = await _dio.get<String>(
        _releasesListApi,
        options: Options(responseType: ResponseType.plain),
      );
      if (response.statusCode != 200 || response.data == null) return null;
      final decoded = jsonDecode(response.data!);
      if (decoded is! List) return null;
      final releases = <Map<String, dynamic>>[
        for (final item in decoded)
          if (item is Map<String, dynamic>) item,
      ];
      _releaseCache = releases;
      _releaseCacheAt = DateTime.now();
      return releases;
    } catch (e) {
      _log.warning('Release 列表读取失败（沿用上一份缓存）: $e');
      return _releaseCache;
    }
  }

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

  /// 右上角通知广播：按发布时间最多同时展示三条，每条单独确认。
  static final ValueNotifier<List<ReleaseNotice>> broadcastNotices =
      ValueNotifier<List<ReleaseNotice>>(const []);

  /// 运行时完整版本号（如 108.1.0.100），未加载完成时为空字符串
  String _currentVersion = '';
  String get currentVersion => _currentVersion;

  /// 初始化：读取完整版本号 + 静默检查远程停用开关（不弹任何 UI）
  /// + 启动后端滥用标记轮询
  Future<void> init() async {
    await UiPrefsService.ensureLoaded();
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

  /// 取消 [init] 建立的两个周期定时器并置空。
  ///
  /// 本服务是进程级单例，正常运行时不需要停止；该入口供测试收尾与
  /// 需要重置单例状态（热重启、集成测试）的场景使用。幂等：可重复调用。
  /// 取消后再次调用 [init] 会重新建立定时器。
  void cancelTimers() {
    _updateTimer?.cancel();
    _updateTimer = null;
    _abuseTimer?.cancel();
    _abuseTimer = null;
  }

  /// 上报一次成绩查询（供客户端防滥用滑动窗口统计）
  void reportQuery() {
    if (disabled.value || _abuseTriggered) return;
    // Flag-1067：客户端防滥用滑动窗口可被远程静默下线
    if (!FeatureGateService.instance.isEnabled(
      FeatureGateService.flag1067AbuseGuard,
    )) {
      return;
    }
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
    // Flag-1067：后端滥用标记轮询同样受该开关控制
    if (!FeatureGateService.instance.isEnabled(
      FeatureGateService.flag1067AbuseGuard,
    )) {
      return;
    }
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
    // Flag-1060：检查更新可被远程静默下线（返回不可用，不打断调用方）
    if (!FeatureGateService.instance.isEnabled(
      FeatureGateService.flag1060CheckUpdate,
    )) {
      return const UpdateCheckResult(ok: false, error: '检查更新当前不可用');
    }
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
          final releases = await _fetchReleaseList();
          if (releases == null) throw Exception('GitHub Release 列表读取失败');
          if (releases.isEmpty) {
            return const UpdateCheckResult(ok: false, error: '仓库暂未发布任何版本');
          }
          // 模拟 /releases/latest：仅取最新正式应用发布，永不把控制配置、
          // 红蓝屏或广播 Release 当作安装包更新。
          Map<String, dynamic>? data;
          for (final item in releases) {
            final tag = (item['tag_name'] ?? '').toString();
            final isPre = item['prerelease'] == true || item['draft'] == true;
            if (!isPre &&
                !isKillSwitchTag(tag) &&
                !isNoticeSeriesTag(tag) &&
                !isGateConfigTag(tag)) {
              data = item;
              break;
            }
          }
          if (data == null) {
            return const UpdateCheckResult(ok: false, error: '未找到正式应用版本');
          }

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

          // control-v* 是独立的「远程功能开关」频道，由后端拉取并验签；
          // 前端只负责把它排除在版本比较之外。
          if (isGateConfigTag(tag)) {
            _log.info('Release $tag 属于功能开关号段，跳过版本比较');
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

  /// 是否为远程功能开关指令 tag（`control-v<rev>`）。
  ///
  /// 该号段由后端消费，前端只负责把它挡在版本比较之外。
  static bool isGateConfigTag(String tag) {
    return tag.trim().startsWith(gateConfigPrefix);
  }

  /// 关闭开发者提醒页：仅清空提示状态，回到 AppNavigation，不退出软件。
  ///
  /// [disabled] 保持 false —— 提醒页从不让 App 进入禁用态。
  static void dismissDeveloperNotice() {
    final notice = releaseNotice.value;
    if (notice == null || notice.kind != NoticeKind.developerNotice) return;
    _instance._dismissedDeveloperTags.add(notice.tag);
    unawaited(
      UiPrefsService.dismissPermanently(_noticeDismissKey('blue', notice.tag)),
    );
    releaseNotice.value = null;
    _instance._log.info('开发者提醒已关闭: ${notice.tag}');
  }

  /// 关闭右上角通知广播卡片，并记住本次确认直到通知被撤回。
  static void dismissBroadcast(ReleaseNotice notice) {
    _instance._dismissedBroadcastTags.add(notice.tag);
    unawaited(
      UiPrefsService.dismissPermanently(
        _noticeDismissKey('broadcast', notice.tag),
      ),
    );
    broadcastNotices.value = List<ReleaseNotice>.unmodifiable(
      broadcastNotices.value.where((item) => item.tag != notice.tag),
    );
    _instance._log.info('通知广播已关闭: ${notice.tag}');
  }

  static String _noticeDismissKey(String kind, String tag) =>
      'release_notice_$kind:${tag.trim()}';

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
      final releases = await _fetchReleaseList();
      if (releases == null) return; // 网络失败：保守地保持现状
      final probes = await Future.wait([
        _probeReleaseFromList(releases, killSwitchVersion, kind: 'red'),
        _probeReleaseFromList(releases, killSwitchVersionFallback, kind: 'red'),
        _probeReleaseFromList(releases, developerNoticeVersion, kind: 'blue'),
        _probeReleaseFromList(
          releases,
          legacyBroadcastDisableVersion,
          kind: 'disable114',
        ),
      ]);
      final primary = probes[0];
      final fallback = probes[1];
      final developer = probes[2];
      final legacyDisable = probes[3];

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
      // Flag-1066：红屏停用页可被远程静默下线。
      // 下线时只清本地禁用态，不覆盖滥用保护（与 _clearKillSwitch 同语义）。
      final killEnabled = FeatureGateService.instance.isEnabled(
        FeatureGateService.flag1066KillSwitch,
      );
      if (!killEnabled) {
        _clearKillSwitch();
      } else if (desired == null) {
        _clearKillSwitch();
      } else if (killEnabled &&
          desired == killSwitchVersion &&
          primary.exists == true) {
        _applyKillSwitch(killSwitchVersion, primary);
      } else if (desired == killSwitchVersionFallback &&
          fallback.exists == true) {
        _applyKillSwitch(killSwitchVersionFallback, fallback);
      }
      // desired 非空但本次没拿到该 tag 的 body：上次已渲染的内容保持不变

      // 2) 开发者提醒判定（独立于停用）：禁用态优先，提醒页不覆盖禁用页
      if (disabled.value) return;
      if (developer.exists == true) {
        // Flag-1065：蓝屏开发者提醒可被远程静默下线
        if (!FeatureGateService.instance.isEnabled(
          FeatureGateService.flag1065DeveloperNotice,
        )) {
          return;
        }
        if (_dismissedDeveloperTags.contains(developerNoticeVersion) ||
            UiPrefsService.isPermanentlyDismissed(
              _noticeDismissKey('blue', developerNoticeVersion),
            )) {
          return;
        }
        _applyDeveloperNotice(developerNoticeVersion, developer);
      } else if (developer.exists == false) {
        // tag 已删除：撤下提醒页，并清掉关闭记录（下次若重建则重新提醒）
        _dismissedDeveloperTags.remove(developerNoticeVersion);
        unawaited(
          UiPrefsService.restorePermanentlyDismissed(
            _noticeDismissKey('blue', developerNoticeVersion),
          ),
        );
        final current = releaseNotice.value;
        if (current != null &&
            current.kind == NoticeKind.developerNotice &&
            current.tag == developerNoticeVersion) {
          releaseNotice.value = null;
        }
      }

      // 3) 广播通知（114 号段里除 513/514/515 之外的 tag）：右上角提示卡
      // 旧 114 普通广播可被本地常量或远程标记整体关闭；两者都不影响
      // 上面的 114.515 蓝屏与 114.514/513 红屏探测。
      // Flag-1064：114 号段广播卡可被远程静默下线
      final broadcastEnabled = FeatureGateService.instance.isEnabled(
        FeatureGateService.flag1064Broadcast,
      );
      if (!broadcastEnabled ||
          !enableLegacy114BroadcastNotices ||
          legacyDisable.exists == true) {
        broadcastNotices.value = const [];
      } else {
        await _checkBroadcast(releases);
      }
    } catch (e) {
      // 任何异常都不改界面：宁可这次不弹，也不误弹/误清
      _log.warning('Release 提示检查异常（保持原状态）: $e');
    }
  }

  /// 在 114 号段里找最多三条待广播的 Release，同时展示到右上角。
  ///
  /// 用列表接口一次取回全部 Release：号段 tag 是按需新增/删除的，
  /// 没有固定名称可逐个探测。列表为空或网络异常时**不动**界面，
  /// 已展示的卡片不会被莫名其妙撤掉。
  Future<void> _checkBroadcast(List<Map<String, dynamic>> releases) async {
    try {
      final hits = <ReleaseNotice>[];
      for (final raw in releases) {
        final tag = _normalizeVersion((raw['tag_name'] ?? '').toString());
        if (!isBroadcastTag(tag)) continue;
        // 广播同样必须验签：列表接口是匿名可读的，只有签名能把
        // 「拥有仓库写权限」与「能让用户看到这条广播」绑定起来。
        final rawBody = (raw['body'] ?? '').toString().trim();
        final verified = await _verifyNotice(tag, rawBody, 'broadcast');
        if (verified == null) {
          _log.warning('广播 $tag 缺少有效签名，跳过');
          continue;
        }
        if (_dismissedBroadcastTags.contains(tag) ||
            UiPrefsService.isPermanentlyDismissed(
              _noticeDismissKey('broadcast', tag),
            )) {
          continue;
        }
        hits.add(
          ReleaseNotice(
            kind: NoticeKind.broadcast,
            title: (raw['name'] ?? '').toString().trim(),
            body: verified,
            tag: tag,
          ),
        );
        // 列表按发布时间倒序，最多保留三条最新通知。
        if (hits.length == 3) break;
      }

      if (hits.isEmpty) {
        // 号段里没有任何广播条目：撤下卡片，并清掉本次进程的关闭记录
        _dismissedBroadcastTags.clear();
        broadcastNotices.value = const [];
        return;
      }
      if (disabled.value) return;
      final current = broadcastNotices.value;
      final same =
          current.length == hits.length &&
          List.generate(
            current.length,
            (index) =>
                current[index].tag == hits[index].tag &&
                current[index].body == hits[index].body,
          ).every((value) => value);
      if (same) return;
      broadcastNotices.value = List<ReleaseNotice>.unmodifiable(hits);
      _log.info('命中 ${hits.length} 条通知广播');
    } catch (e) {
      _log.warning('广播通知检查失败（保持原状态）: $e');
    }
  }

  /// 从共享 Release 列表中探测固定通知 tag。列表请求失败时调用方保持现状；
  /// 成功列表中不存在即是确定的“已删除”。
  Future<_TagProbe> _probeReleaseFromList(
    List<Map<String, dynamic>> releases,
    String tag, {
    required String kind,
  }) async {
    try {
      Map<String, dynamic>? item;
      for (final release in releases) {
        if ((release['tag_name'] ?? '').toString() == tag) {
          item = release;
          break;
        }
      }
      if (item == null) return const _TagProbe(exists: false);
      final body = (item['body'] ?? '').toString().trim();
      final verified = await _verifyNotice(tag, body, kind);
      if (verified == null) {
        _log.warning('Release $tag 缺少有效签名，按未生效处理');
        return const _TagProbe(exists: null);
      }
      return _TagProbe(
        exists: true,
        title: (item['name'] ?? '').toString().trim(),
        body: verified,
      );
    } catch (e) {
      // 超时 / 连接失败 / 5xx：无法判定，绝不当作删除
      _log.warning('Release $tag 查询失败（保持原状态）: $e');
      return const _TagProbe(exists: null);
    }
  }

  /// 校验一条远程通知的签名，通过则返回去掉签名块后的正文，否则 null。
  ///
  /// 三重绑定：签名块里的 `tag` 必须等于实际 tag、`kind` 必须等于该通道
  /// 的期望值、`sha256` 必须等于去掉签名块后的正文摘要。任何一条不满足
  /// 都视为无效——这样即使有人拿到仓库写权限，也伪造不出一条能弹屏的通知。
  Future<String?> _verifyNotice(String tag, String body, String kind) async {
    if (body.isEmpty) return null;
    final notice = UpdateVerifier.parseNotice(body);
    if (notice == null) return null;
    if (notice.kind != kind) {
      _log.warning('Release $tag 签名块的 kind=${notice.kind}，该通道期望 $kind');
      return null;
    }
    if (notice.tag != tag) {
      _log.warning('Release $tag 签名块声明的 tag=${notice.tag}，与实际不符');
      return null;
    }
    final result = await UpdateVerifier.verifyNotice(notice, body);
    if (!result.ok) {
      _log.warning('Release $tag 通知验签失败：${result.reason}');
      return null;
    }
    return UpdateVerifier.stripNoticeBlocks(body).trim();
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
    @visibleForTesting Directory? destinationDirectory,
  }) async {
    final dir = destinationDirectory ?? Directory(_downloadsDir());
    final dirPath = dir.path;
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

    // 上次中断留下的 .part 文件可直接续传。大于发布资产标称大小的
    // 临时文件不可能有效，避免 Range 起点落在文件末尾之后。
    var resumeOffset = tmpFile.existsSync() ? tmpFile.lengthSync() : 0;
    if (asset.size > 0 && resumeOffset > asset.size) {
      tmpFile.deleteSync();
      resumeOffset = 0;
    }
    if (asset.size > 0 && resumeOffset == asset.size) {
      tmpFile.renameSync(targetPath);
      _log.info('更新包已从完整的临时文件恢复: $targetPath');
      onProgress?.call(asset.size, asset.size);
      return targetPath;
    }

    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        headers: {'User-Agent': 'GradeMonitor-UpdateDownload'},
        followRedirects: true,
        validateStatus: (status) => status != null && status < 400,
      ),
    );
    // Dart 桌面端不保证自动继承浏览器的代理路径。显式读取
    // HTTP_PROXY / HTTPS_PROXY / NO_PROXY，使常见的系统代理启动器和
    // 命令行环境与应用内下载保持一致。
    (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
      final client = HttpClient();
      client.findProxy = (uri) => HttpClient.findProxyFromEnvironment(
        uri,
        environment: Platform.environment,
      );
      return client;
    };

    Future<void> runDownload(int offset) async {
      final resuming = offset > 0;
      await dio.download(
        asset.url,
        tmpPath,
        onReceiveProgress: (received, total) {
          final overallReceived = offset + received;
          final overallTotal = total > 0
              ? offset + total
              : (asset.size > 0 ? asset.size : total);
          onProgress?.call(overallReceived, overallTotal);
        },
        options: Options(
          responseType: ResponseType.bytes,
          headers: resuming ? {'Range': 'bytes=$offset-'} : null,
          // 续传必须得到 206。若服务器忽略 Range 返回 200，
          // Dio 会在写文件前拒绝该响应，防止把整包追加两次。
          validateStatus: (status) => resuming
              ? status == 206
              : status != null && status >= 200 && status < 300,
        ),
        fileAccessMode: resuming ? FileAccessMode.append : FileAccessMode.write,
        // 保留已下载内容，下次从断点继续。
        deleteOnError: false,
      );
    }

    try {
      try {
        await runDownload(resumeOffset);
      } on DioException catch (e) {
        // 一些 CDN 不支持 Range，或签名 URL 变化后不接受旧断点。
        // 仅在“续传请求已到达服务器但未获得 206”时从头下载；
        // DNS、连接中断等错误仍保留断点。
        if (resumeOffset > 0 && e.response?.statusCode != null) {
          if (tmpFile.existsSync()) tmpFile.deleteSync();
          resumeOffset = 0;
          await runDownload(0);
        } else {
          rethrow;
        }
      }
      final tmp = File(tmpPath);
      if (!tmp.existsSync()) {
        throw Exception('下载未完成（临时文件丢失）');
      }
      final downloadedSize = tmp.lengthSync();
      if (asset.size > 0 && downloadedSize != asset.size) {
        throw Exception('下载文件大小不符（$downloadedSize / ${asset.size} 字节）');
      }
      tmp.renameSync(targetPath);
      _log.info('更新包已下载: $targetPath');
      return targetPath;
    } catch (e) {
      _log.warning('下载更新包失败（已保留断点）: $e');
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
