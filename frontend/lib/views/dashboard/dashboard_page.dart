import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/service/nav_signal.dart';
import '../../core/theme/app_theme.dart';
import '../../core/network/websocket_service.dart';
import '../../providers/monitor_provider.dart';
import '../../providers/grades_provider.dart';
import '../../providers/settings_provider.dart';
import '../../core/service/feature_gate_service.dart';
import '../../widgets/feature_gate.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/toast_host.dart';

class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});
  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  /// 底部统计卡的网格常量。卡间缝隙固定 4px，两行用同一个值，
  /// 因此上下两行的左右边界天然对齐（等价于 CSS Grid 的 gap: 4px）。
  ///
  /// 行高与字号按默认 1100×720 窗口标定：整页（标题 + 监控行 + 最新出分
  /// + 两行统计卡）在默认窗口内不出现纵向滚动，布局比例保持不变。
  static const double _statGap = 4;
  static const double _statTopRowHeight = 145;
  static const double _statBottomRowHeight = 112;
  static const double _statIconSize = 24;
  static const double _statLabelSize = 15;
  /// 字号自适应下限：再窄也不低于这个值，溢出交给 FittedBox 兜底
  static const double _statNumberMin = 26;

  bool _settingsReady = false;
  String? _lastUsername;
  bool _isQuerying = false;
  bool _isTogglingMonitor = false;

  /// 最近一次成绩/排名变动的通知内容（后端 recent_change.json）
  Map<String, dynamic>? _latestChange;

  @override
  void initState() {
    super.initState();
    Future.microtask(_initLoad);
    final ws = ref.read(webSocketProvider);
    ws.connect();
    ws.eventStream.listen((event) {
      if (event.type == WsEventType.gradesChanged ||
          event.type == WsEventType.rankChanged) {
        ref.read(monitorProvider.notifier).fetchStatus();
        ref.read(gradesProvider.notifier).fetchGrades();
        ref.read(rankProvider.notifier).fetchRank();
        _fetchLatestChange();
      }
    });
  }

  Future<void> _initLoad() async {
    // 先加载设置
    await ref.read(settingsProvider.notifier).fetchSettings();
    final settings = ref.read(settingsProvider);
    _lastUsername = settings.username;

    // 加载缓存数据（后端已在内存中持有）
    await _refreshAll();

    // 如果开启了自动监控但未运行，自动启动
    if (!mounted) return;
    final status = ref.read(monitorProvider);
    if ((settings.autoMonitorEnabled || settings.rankMonitorEnabled) &&
        !status.isRunning &&
        settings.username.isNotEmpty) {
      try {
        await ref.read(monitorProvider.notifier).startMonitor();
        ref.read(monitorProvider.notifier).fetchStatus();
      } catch (_) {}
    }

    setState(() => _settingsReady = true);
  }

  Future<void> _refreshAll() async {
    await ref.read(monitorProvider.notifier).fetchStatus();
    await ref.read(gradesProvider.notifier).fetchGrades();
    await ref.read(rankProvider.notifier).fetchRank();
    await _fetchLatestChange();
  }

  /// 读取后端记录的最近一次变动通知（成绩/排名）
  Future<void> _fetchLatestChange() async {
    try {
      final resp = await ref.read(apiClientProvider).getLatestChange();
      final data = Map<String, dynamic>.from(resp.data as Map);
      final change = data['change'];
      if (!mounted) return;
      setState(() {
        _latestChange = change is Map<String, dynamic> ? change : null;
      });
    } catch (_) {
      // 无记录时静默保持空态
    }
  }

  Future<void> _queryOnce() async {
    setState(() => _isQuerying = true);
    final api = ref.read(apiClientProvider);
    try {
      await api.queryOnce();
      await _refreshAll();
    } catch (e) {
      if (mounted) {
        ToastHost().show('查询失败: $e');
      }
    } finally {
      if (mounted) setState(() => _isQuerying = false);
    }
  }

  /// 启动/停止监控（带 loading 与结果反馈）
  Future<void> _toggleMonitor() async {
    if (_isTogglingMonitor) return;
    setState(() => _isTogglingMonitor = true);
    try {
      final status = ref.read(monitorProvider);
      final s = ref.read(settingsProvider);
      if (status.isRunning) {
        // 停止监控 + 关闭设置中的自动监控开关
        await ref
            .read(settingsProvider.notifier)
            .saveSettings(
              s.copyWith(autoMonitorEnabled: false, rankMonitorEnabled: false),
            );
        await ref.read(monitorProvider.notifier).stopMonitor();
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('监控已停止')));
        }
      } else {
        // 启动监控 + 打开设置中的成绩自动监控开关
        await ref
            .read(settingsProvider.notifier)
            .saveSettings(s.copyWith(autoMonitorEnabled: true));
        await ref.read(monitorProvider.notifier).startMonitor();
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('监控已启动，将按间隔自动查询')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      await ref.read(monitorProvider.notifier).fetchStatus();
      if (mounted) setState(() => _isTogglingMonitor = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final monitorState = ref.watch(monitorProvider);
    final gradesAsync = ref.watch(gradesProvider);
    final rankAsync = ref.watch(rankProvider);
    final settings = ref.watch(settingsProvider);
    final colorScheme = Theme.of(context).colorScheme;

    if (_settingsReady &&
        _lastUsername != null &&
        _lastUsername != settings.username) {
      _lastUsername = settings.username;
      Future.microtask(_refreshAll);
    }

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 44, 28, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '仪表板',
                style: TextStyle(
                  fontFamily: AppTheme.serifFontFamily,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 20),
              FeatureGate(
                flag: FeatureGateService.flag1001Monitor,
                child: _buildMonitorCard(monitorState),
              ),
              FeatureGate(
                flag: FeatureGateService.flag1003LatestCard,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 18),
                    _buildLatestCard(gradesAsync),
                  ],
                ),
              ),
              FeatureGate(
                flag: FeatureGateService.flag1004StatTiles,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 18),
                    _buildStatTiles(monitorState, rankAsync),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 监控状态卡（整行）：状态与按钮在同一行垂直居中，按钮靠右
  Widget _buildMonitorCard(MonitorStatus status) {
    final colorScheme = Theme.of(context).colorScheme;

    // 监控状态行不再套白底卡片：状态与按钮直接落在页面背景上，
    // 只靠文字颜色与两枚带浅色底的按钮区分层级。
    // 去掉卡片后需要自行补足上下留白，否则与标题、最新出分卡贴得过紧。
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 20),
      constraints: const BoxConstraints(minHeight: 56),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          PulsingStatusDot(active: status.isRunning),
          const SizedBox(width: 12),
          Text(
            status.isRunning ? '监控运行中' : '监控已停止',
            style: TextStyle(
              fontFamily: AppTheme.serifFontFamily,
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: status.isRunning
                  ? AppTheme.success
                  : colorScheme.onSurface.withValues(alpha: .5),
            ),
          ),
          const Spacer(),
          // Flag-1002：立即查询按钮可被远程静默下线
          FeatureGate(
            flag: FeatureGateService.flag1002QueryOnce,
            child: _ControlButton(
              icon: _isQuerying ? null : Icons.search_rounded,
              label: _isQuerying ? '查询中，请稍候' : '立即查询',
              color: colorScheme.primary,
              loading: _isQuerying,
              onTap: _isQuerying ? null : _queryOnce,
            ),
          ),
          const SizedBox(width: 10),
          _ControlButton(
            icon: status.isRunning
                ? Icons.stop_rounded
                : Icons.play_arrow_rounded,
            label: status.isRunning ? '停止监控' : '启动监控',
            color: status.isRunning ? AppTheme.error : AppTheme.success,
            loading: _isTogglingMonitor,
            onTap: _isTogglingMonitor ? null : _toggleMonitor,
          ),
        ],
      ),
    );
  }

  /// 「最新出分」卡：展示最近一次成绩（或排名）变动的结构化内容。
  /// 数据源：后端 recent_change.json（courses 为结构化课程数组）。
  Widget _buildLatestCard(AsyncValue<List<GradeCourse>> gradesAsync) {
    final cs = Theme.of(context).colorScheme;
    final settings = ref.read(settingsProvider);
    final tinyColor = cs.onSurface.withValues(alpha: .3);
    final change = _latestChange;

    final entries = _parseEntries(change, gradesAsync.asData?.value);
    final at = (change?['at'] ?? '').toString();

    // 小标题：1 门=课程名；2 门=「课程名 等 2 门」；3 门以上=n 门课程有更新
    String subtitle;
    String body;
    var tagText = '最新出分';
    var tagColor = AppTheme.success;
    var empty = false;

    if (entries.isNotEmpty) {
      // 课程总数优先取后端 courseCount（courses 已按 6 条截断）
      final rawCount = change?['courseCount'];
      var n = rawCount is int && rawCount > 0 ? rawCount : entries.length;
      // courses 可能因后端截断少于 courseCount，展示时不能超过实际条数
      if (n > entries.length && entries.length < 3) n = entries.length;
      if (n == 1) {
        subtitle = entries.first.name;
        body = _entryLine(entries.first, withName: false);
      } else if (n == 2) {
        subtitle = '${entries.first.name} 等 2 门';
        body =
            '${_entryLine(entries[0], withName: true)}\n'
            '${_entryLine(entries[1], withName: true)}';
      } else {
        subtitle = '$n 门课程有更新';
        body = '多门成绩更新，请前往“成绩单”页面查看具体情况';
      }
    } else if (change != null) {
      // 排名等其他变动，或后端尚未提供结构化字段时的兼容展示
      final raw = (change['title'] ?? '').toString();
      final idx = raw.indexOf('：');
      subtitle = idx >= 0
          ? raw.substring(idx + 1)
          : (raw.isEmpty ? '成绩与排名更新' : raw);
      final msg = (change['message'] ?? '').toString();
      body = msg.isEmpty ? '详情见「成绩单」' : msg.replaceAll('\n', '　·　');
    } else {
      empty = true;
      tagText = '暂无更新';
      tagColor = cs.onSurface.withValues(alpha: .45);
      final latest = _latestCourse(gradesAsync.asData?.value);
      if (latest == null) {
        subtitle = settings.username.isEmpty ? '请先在设置中配置账户' : '暂无成绩数据';
        body = '完成监控配置后，成绩与排名变动会第一时间展示在这里';
      } else {
        subtitle = latest.kcname;
        body = _entryLine(
          _LatestEntry(
            name: latest.kcname,
            gpa: _avgGpaOf(latest),
            daily: latest.cjxm1,
            finalScore: latest.cjxm3,
            weighted: latest.zcj,
          ),
          withName: false,
        );
      }
    }

    return GlassCard(
      // 仪表板整页保持更大的组合圆角，与下方统计卡组同一套轮廓。
      borderRadius: AppShape.cornerHero,
      padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _TagChip(tagText, tagColor),
              const Spacer(),
              // 右上角：跳转成绩单页（蓝色文字按钮，无药丸形态）
              TextButton(
                onPressed: () => requestNav(AppNavTarget.grades),
                style: TextButton.styleFrom(
                  foregroundColor: cs.primary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 2,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  '查看完整成绩 →',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: cs.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: AppTheme.serifFontFamily,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              height: 1.6,
              color: empty ? cs.onSurface.withValues(alpha: .45) : cs.onSurface,
            ),
          ),
          if (at.isNotEmpty) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                at,
                style: TextStyle(fontSize: 11.5, color: tinyColor),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 单门成绩正文：绩点 / 平时成绩 / 期末成绩 / 加权成绩
  String _entryLine(_LatestEntry e, {required bool withName}) {
    final prefix = withName ? '${e.name}： ' : '';
    return '$prefix绩点：${e.gpa}   平时成绩：${_dashIfEmpty(e.daily)}   '
        '期末成绩：${_dashIfEmpty(e.finalScore)}   加权成绩：${_dashIfEmpty(e.weighted)}';
  }

  String _dashIfEmpty(String v) => v.trim().isEmpty ? '-' : v.trim();

  /// 平均学分绩点（Σ学分绩点 ÷ Σ学分，单课即 jd/xf），最高 4.0
  String _avgGpaOf(GradeCourse c) {
    final xf = double.tryParse(c.xf) ?? 0;
    final jd = double.tryParse(c.jd) ?? 0;
    if (xf <= 0) return '0.0';
    return (jd / xf).toStringAsFixed(1);
  }

  /// 解析后端结构化 courses；缺失时回退到本地最新一门成绩
  List<_LatestEntry> _parseEntries(
    Map<String, dynamic>? change,
    List<GradeCourse>? grades,
  ) {
    final raw = change?['courses'];
    final list = <_LatestEntry>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final m = Map<String, dynamic>.from(item);
        final name = (m['name'] ?? '').toString().trim();
        if (name.isEmpty) continue;
        list.add(
          _LatestEntry(
            name: name,
            gpa: _dashIfEmpty((m['gpa'] ?? '').toString()),
            daily: (m['daily'] ?? '').toString(),
            finalScore: (m['final'] ?? '').toString(),
            weighted: (m['weighted'] ?? '').toString(),
          ),
        );
      }
    }
    if (list.isNotEmpty) return list;

    // 后端旧格式（无 courses）：若标题里带课程名且本地有对应课程则补齐字段
    if (change != null) return const [];

    final latest = _latestCourse(grades);
    if (latest == null) return const [];
    return [
      _LatestEntry(
        name: latest.kcname,
        gpa: _avgGpaOf(latest),
        daily: latest.cjxm1,
        finalScore: latest.cjxm3,
        weighted: latest.zcj,
      ),
    ];
  }

  /// 取最新一门成绩：最新学期（xnxq 降序）中后端列表的最后一门
  GradeCourse? _latestCourse(List<GradeCourse>? grades) {
    if (grades == null || grades.isEmpty) return null;
    final settings = ref.read(settingsProvider);
    final list = settings.hideUnknownCourses
        ? grades.where((g) => g.kcname != '未知课程').toList()
        : grades.toList();
    if (list.isEmpty) return null;

    final latestSem = list
        .map((g) => g.xnxq)
        .reduce((a, b) => b.compareTo(a) > 0 ? b : a);
    GradeCourse? result;
    for (final g in list) {
      if (g.xnxq == latestSem) result = g;
    }
    return result;
  }

  /// 底部统计卡：Bento Grid（上三下二），五张卡共用同一个背景 Token。
  ///
  /// 视觉上拼成一个完整的大圆角矩形：只有组合最外侧四角是
  /// [AppShape.cornerHero]，其余一律 [AppShape.cornerSmall]，
  /// 卡与卡之间留 4px 缝隙露出页面底色。
  /// 顺序：GPA → 班级排名 → 专业排名 → 修读课程 → 查询次数
  Widget _buildStatTiles(
    MonitorStatus status,
    AsyncValue<RankData?> rankAsync,
  ) {
    final rd = rankAsync.asData?.value;

    final topRow = <_StatTileData>[
      _StatTileData(
        icon: Icons.school_rounded,
        iconColor: const Color(0xFF8B5CF6),
        label: 'GPA',
        value: rd?.pjxfjd ?? 'N/A',
        numberSize: 76,
        decimalSmall: true,
      ),
      _StatTileData(
        icon: Icons.groups_rounded,
        iconColor: const Color(0xFFF59E0B),
        label: '班级排名',
        value: rd?.bjpm ?? 'N/A',
        numberSize: 64,
      ),
      _StatTileData(
        icon: Icons.emoji_events_rounded,
        iconColor: const Color(0xFF6366F1),
        label: '专业排名',
        value: rd?.pm ?? 'N/A',
        numberSize: 64,
      ),
    ];

    final bottomRow = <_StatTileData>[
      _StatTileData(
        icon: Icons.menu_book_rounded,
        iconColor: const Color(0xFF10B981),
        label: '修读课程',
        value: rd?.countnum ?? 'N/A',
        numberSize: 60,
      ),
      // Flag-1073：查询次数卡可被远程下线；下线后修读课程卡独占整行，
      // 角落规则由 _statCornerRadius 按实际位置推导，不需要另写分支。
      if (featureEnabled(FeatureGateService.flag1073QueryCount))
        _StatTileData(
          icon: Icons.query_stats_rounded,
          iconColor: const Color(0xFF3B82F6),
          label: '查询次数',
          value: '${status.totalQueries}',
          numberSize: 60,
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: _statTopRowHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _statRow(
              topRow,
              isTopRow: true,
              isBottomRow: false,
              vertical: true,
            ),
          ),
        ),
        const SizedBox(height: _statGap),
        SizedBox(
          height: _statBottomRowHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _statRow(
              bottomRow,
              isTopRow: false,
              isBottomRow: true,
              vertical: false,
            ),
          ),
        ),
      ],
    );
  }

  /// 一行卡片的子节点：`Expanded` 等分即 CSS Grid 的 `repeat(n, 1fr)`。
  /// 缝隙是固定 4px 的 SizedBox，所以上下两行的左右边界必然对齐。
  List<Widget> _statRow(
    List<_StatTileData> items, {
    required bool isTopRow,
    required bool isBottomRow,
    required bool vertical,
  }) {
    final row = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      if (i > 0) row.add(const SizedBox(width: _statGap));
      row.add(
        Expanded(
          child: _StatCard(
            radius: _statCornerRadius(
              isTopRow: isTopRow,
              isBottomRow: isBottomRow,
              isFirst: i == 0,
              isLast: i == items.length - 1,
            ),
            child: vertical
                ? _statTileVertical(items[i])
                : _statTileHorizontal(items[i]),
          ),
        ),
      );
    }
    return row;
  }

  /// 组合式圆角：只有整个组合最外侧的四个角用大圆角，其余全是小圆角。
  /// 规则统一收在 [AppShape.gridCell]，与全程序其余容器保持一致。
  BorderRadius _statCornerRadius({
    required bool isTopRow,
    required bool isBottomRow,
    required bool isFirst,
    required bool isLast,
  }) => AppShape.gridCell(
    topRow: isTopRow,
    bottomRow: isBottomRow,
    first: isFirst,
    last: isLast,
  );

  /// 数字字号随卡片可用宽度收缩，但不超过设计稿字号，也不低于 [min]。
  double _statNumberSize(double available, double design, double factor) =>
      (available * factor).clamp(_statNumberMin, design).toDouble();

  /// 第一行：顶部图标+指标名，超大数字沉到底部。
  ///
  /// 数字用 Spacer 顶到卡片底边而不是居中，是为了让 GPA(104) 与两个排名(88)
  /// 三个不同字号的数字共享同一条基线 —— 标题基线与内边距也因此完全一致。
  Widget _statTileVertical(_StatTileData tile) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = _statNumberSize(
            constraints.maxWidth,
            tile.numberSize,
            .45,
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _statHeader(tile, cs),
              const Spacer(),
              _statNumber(tile.value, size, cs, decimalSmall: tile.decimalSmall),
            ],
          );
        },
      ),
    );
  }

  /// 第二行：左侧图标+指标名，右侧超大数字，左右垂直居中、数字靠右。
  Widget _statTileHorizontal(_StatTileData tile) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 20, 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = _statNumberSize(
            constraints.maxWidth,
            tile.numberSize,
            .23,
          );
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 左侧留 6 份，保证「修读课程」这类四字标签在最小窗口下不被截断
              Expanded(flex: 6, child: _statHeader(tile, cs)),
              const SizedBox(width: 16),
              Expanded(
                flex: 5,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _statNumber(
                    tile.value,
                    size,
                    cs,
                    decimalSmall: tile.decimalSmall,
                    alignRight: true,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 图标 + 指标名（同一行，两行卡片共用，保证基线与内边距一致）
  Widget _statHeader(_StatTileData tile, ColorScheme cs) {
    return Row(
      children: [
        Icon(tile.icon, size: _statIconSize, color: tile.iconColor),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            tile.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: _statLabelSize,
              fontWeight: FontWeight.w600,
              height: 1.1,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  /// 超大统计数字。Regular 字重 + 等宽数字，小数点与多位数按比例缩小。
  Widget _statNumber(
    String value,
    double size,
    ColorScheme cs, {
    bool decimalSmall = false,
    bool alignRight = false,
  }) {
    final base = TextStyle(
      fontSize: size,
      fontWeight: FontWeight.w400,
      height: 1.0,
      letterSpacing: size * -.015,
      color: cs.onSurface,
      // tabular-nums：位数变化时数字宽度不跳动，视觉中心保持稳定
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final dot = decimalSmall ? value.indexOf('.') : -1;

    final Widget text;
    if (dot >= 0) {
      // GPA：整数部分满字号，小数部分缩到一半，两者共享同一条基线
      text = Text.rich(
        TextSpan(
          style: base,
          children: [
            TextSpan(text: value.substring(0, dot)),
            TextSpan(
              text: value.substring(dot),
              style: TextStyle(fontSize: size * .5),
            ),
          ],
        ),
        maxLines: 1,
      );
    } else {
      // 整串数字同一字号：位数变化只影响总宽，不产生大小混排，
      // 数字的视觉重心因此始终落在卡片内的同一位置
      text = Text(value, maxLines: 1, style: base);
    }

    // 兜底：窗口被拖到极窄时等比缩小，绝不允许裁切或溢出
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: text,
    );
  }
}

/// 底部统计卡的一张卡：统一的容器底色 + 由位置推导的组合式圆角。
class _StatCard extends StatelessWidget {
  const _StatCard({required this.radius, required this.child});
  final BorderRadius radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      // 五张卡共用同一个主题 Token（与重构前的统计卡一致）
      color: AppShape.groupFill(Theme.of(context).colorScheme),
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// 底部统计卡的展示数据
class _StatTileData {
  const _StatTileData({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    required this.numberSize,
    this.decimalSmall = false,
  });
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;

  /// 设计稿字号上限，实际渲染值按卡片宽度收缩
  final double numberSize;
  final bool decimalSmall;
}

class _TagChip extends StatelessWidget {
  final String text;
  final Color color;
  const _TagChip(this.text, this.color);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: AppShape.inner,
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
    ),
  );
}

class _ControlButton extends StatelessWidget {
  final IconData? icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  final bool loading;
  const _ControlButton({
    this.icon,
    required this.label,
    required this.color,
    this.onTap,
    this.loading = false,
  });
  @override
  Widget build(BuildContext c) => Material(
    color: color.withValues(alpha: .1),
    borderRadius: AppShape.inner,
    child: InkWell(
      onTap: onTap,
      borderRadius: AppShape.inner,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading) ...[
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.blueAccent,
                ),
              ),
              const SizedBox(width: 8),
            ] else if (icon != null) ...[
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 最新出分卡的一门课程数据
class _LatestEntry {
  final String name;
  final String gpa;
  final String daily;
  final String finalScore;
  final String weighted;
  const _LatestEntry({
    required this.name,
    required this.gpa,
    required this.daily,
    required this.finalScore,
    required this.weighted,
  });
}
