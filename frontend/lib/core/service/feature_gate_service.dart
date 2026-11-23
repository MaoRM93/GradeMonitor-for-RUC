import 'package:flutter/foundation.dart';

import '../logger/app_logger.dart';
import '../network/api_client.dart';

/// 功能组开关（Flag-1xxx）的客户端缓存。
///
/// 与开发者选项里的调谐开关（1.x / 2.x，见 `developer_options.dart`）是两套：
///   - 调谐开关面向调试，默认关闭；
///   - 功能组开关面向「远程静默下线」，默认**全部开启**。
///
/// 语义约定：
///   - 未知编号一律视为**开启**（与后端 `gate_enabled` 一致）——写错一个编号
///     不应该让功能凭空消失；
///   - 拉取失败时保留上一次的内存值；从未成功过则全部按开启处理，
///     保证离线/后端未起时界面不残缺；
///   - [states] 是 [ValueNotifier]，界面用 `ValueListenableBuilder` 订阅即可
///     在开关变化后自动重绘。
class FeatureGateService {
  FeatureGateService._();

  static final FeatureGateService instance = FeatureGateService._();

  final _log = AppLogger('feature-gate');

  static const String flag1001Monitor = 'Flag-1001';
  static const String flag1002QueryOnce = 'Flag-1002';
  static const String flag1003LatestCard = 'Flag-1003';
  static const String flag1004StatTiles = 'Flag-1004';

  static const String flag1010Search = 'Flag-1010';
  static const String flag1011SemesterFilter = 'Flag-1011';
  static const String flag1012CoreRange = 'Flag-1012';
  static const String flag1013CoreBadge = 'Flag-1013';
  static const String flag1014SemesterStats = 'Flag-1014';
  static const String flag1015Sort = 'Flag-1015';
  static const String flag1016HideUnknown = 'Flag-1016';

  static const String flag1020SchemeChooser = 'Flag-1020';
  static const String flag1021CoreCard = 'Flag-1021';
  static const String flag1022Inputs = 'Flag-1022';
  static const String flag1023Result = 'Flag-1023';
  static const String flag1024Curriculum = 'Flag-1024';
  static const String flag1025Progress = 'Flag-1025';
  static const String flag1026ProgressBeta = 'Flag-1026';
  static const String flag1027Fitness = 'Flag-1027';
  static const String flag1028MatchRules = 'Flag-1028';
  static const String flag1029FailedCourses = 'Flag-1029';

  static const String flag1030Bark = 'Flag-1030';
  static const String flag1031Meow = 'Flag-1031';
  static const String flag1032Ntfy = 'Flag-1032';
  static const String flag1033ForwarderTest = 'Flag-1033';

  static const String flag1040Agreement = 'Flag-1040';
  static const String flag1041LoginMode = 'Flag-1041';
  static const String flag1042Account = 'Flag-1042';
  static const String flag1043MonitorStep = 'Flag-1043';
  static const String flag1044NotifyStep = 'Flag-1044';
  static const String flag1045Confirm = 'Flag-1045';

  static const String flag1050TitleBar = 'Flag-1050';
  static const String flag1051SideNav = 'Flag-1051';
  static const String flag1052Tray = 'Flag-1052';
  static const String flag1053Notification = 'Flag-1053';
  static const String flag1054NotificationTap = 'Flag-1054';
  static const String flag1055AutoStart = 'Flag-1055';
  static const String flag1056ProgressBetaBadge = 'Flag-1056';

  static const String flag1060CheckUpdate = 'Flag-1060';
  static const String flag1061Download = 'Flag-1061';
  static const String flag1062AutoInstall = 'Flag-1062';
  static const String flag1063Signature = 'Flag-1063';
  static const String flag1064Broadcast = 'Flag-1064';
  static const String flag1065DeveloperNotice = 'Flag-1065';
  static const String flag1066KillSwitch = 'Flag-1066';
  static const String flag1067AbuseGuard = 'Flag-1067';

  static const String flag1070GradesCache = 'Flag-1070';
  static const String flag1071RankCache = 'Flag-1071';
  static const String flag1072RecentChange = 'Flag-1072';
  static const String flag1073QueryCount = 'Flag-1073';
  static const String flag1074WebSocket = 'Flag-1074';
  static const String flag1075Curriculum = 'Flag-1075';

  static const String flag1080LoginJw = 'Flag-1080';
  static const String flag1081LoginCas = 'Flag-1081';
  static const String flag1082LoginVruc = 'Flag-1082';
  static const String flag1083SessionRestore = 'Flag-1083';
  static const String flag1084Logout = 'Flag-1084';
  static const String flag1085Captcha = 'Flag-1085';

  static const String flag1090AutoGrades = 'Flag-1090';
  static const String flag1091AutoRank = 'Flag-1091';
  static const String flag1092TimeWindow = 'Flag-1092';
  static const String flag1093RandomInterval = 'Flag-1093';
  static const String flag1094FirstQuery = 'Flag-1094';
  static const String flag1095StartupNotice = 'Flag-1095';
  static const String flag1096ItemDetail = 'Flag-1096';
  static const String flag1097UnmatchedAssign = 'Flag-1097';
  static const String flag1098ExemptionNote = 'Flag-1098';
  static const String flag1099DashBar = 'Flag-1099';

  /// 当前开关表；订阅它即可跟随远程开关重绘。
  final ValueNotifier<Map<String, bool>> states =
      ValueNotifier<Map<String, bool>>(<String, bool>{});

  /// 注册表元数据（id / name / desc / group），供开发者面板展示。
  final ValueNotifier<List<Map<String, dynamic>>> registry =
      ValueNotifier<List<Map<String, dynamic>>>(const <Map<String, dynamic>>[]);

  bool _loaded = false;
  Future<void>? _inFlight;

  /// 是否已成功拉取过一次。
  bool get loaded => _loaded;

  /// 单个开关是否开启；未知编号视为开启。
  bool isEnabled(String id) => states.value[id] ?? true;

  /// 拉取开关表。并发调用共享同一次请求。
  Future<void> ensureLoaded({bool force = false}) {
    if (_loaded && !force) return Future<void>.value();
    final running = _inFlight;
    if (running != null) return running;

    final future = _load();
    _inFlight = future;
    return future.whenComplete(() => _inFlight = null);
  }

  Future<void> _load() async {
    try {
      final res = await ApiClient().getFeatures();
      final raw = res.data;
      final list = raw is Map ? raw['features'] : null;
      if (list is! List) {
        _log.warning('功能组开关返回结构异常，沿用当前状态');
        return;
      }

      final next = <String, bool>{};
      final meta = <Map<String, dynamic>>[];
      for (final item in list) {
        if (item is! Map) continue;
        final id = item['id'];
        if (id is! String || id.isEmpty) continue;
        next[id] = item['enabled'] != false;
        meta.add(<String, dynamic>{
          'id': id,
          'name': item['name'] ?? '',
          'desc': item['desc'] ?? '',
          'group': item['group'] ?? '',
        });
      }

      states.value = next;
      registry.value = meta;
      _loaded = true;
    } catch (e) {
      // 后端未起 / 断网 / 令牌未就绪：保持现状，界面按"全开"渲染
      _log.warning('拉取功能组开关失败，沿用当前状态: $e');
    }
  }

  /// 本地写回（开发者面板切开关后调用，避免再拉一次列表）。
  void applyLocal(Map<String, bool> gates) {
    final next = Map<String, bool>.from(states.value);
    next.addAll(gates);
    states.value = next;
  }
}
