import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/service/nav_signal.dart';
import '../../core/theme/app_theme.dart';
import '../../core/network/websocket_service.dart';
import '../../providers/monitor_provider.dart';
import '../../providers/grades_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/toast_host.dart';

class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});
  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
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
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 20),
              _buildMonitorCard(monitorState),
              const SizedBox(height: 18),
              _buildLatestCard(gradesAsync),
              const SizedBox(height: 18),
              _buildStatTiles(monitorState, rankAsync),
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
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: status.isRunning
                    ? AppTheme.success
                    : colorScheme.onSurface.withValues(alpha: .5),
              ),
            ),
            const Spacer(),
            _ControlButton(
              icon: _isQuerying ? null : Icons.search_rounded,
              label: _isQuerying ? '查询中，请稍候' : '立即查询',
              color: colorScheme.primary,
              loading: _isQuerying,
              onTap: _isQuerying ? null : _queryOnce,
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
        body = '${_entryLine(entries[0], withName: true)}\n'
            '${_entryLine(entries[1], withName: true)}';
      } else {
        subtitle = '$n 门课程有更新';
        body = '多门成绩更新，请前往“成绩单”页面查看具体情况';
      }
    } else if (change != null) {
      // 排名等其他变动，或后端尚未提供结构化字段时的兼容展示
      final raw = (change['title'] ?? '').toString();
      final idx = raw.indexOf('：');
      subtitle = idx >= 0 ? raw.substring(idx + 1) : (raw.isEmpty ? '成绩与排名更新' : raw);
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
                  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
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
              color: empty
                  ? cs.onSurface.withValues(alpha: .45)
                  : cs.onSurface,
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

  /// 底部统计卡（Lenovo Vantage 风格：左上图标+灰字说明，右下大数字）
  /// 顺序：GPA → 班级排名 → 专业排名 → 修读课程 → 查询次数
  Widget _buildStatTiles(MonitorStatus status, AsyncValue<RankData?> rankAsync) {
    final rd = rankAsync.asData?.value;
    return SizedBox(
      height: 200,
      child: Row(
        children: [
          Expanded(
            child: _statTile(
              icon: Icons.school_rounded,
              iconColor: const Color(0xFF8B5CF6),
              label: 'GPA',
              value: rd?.pjxfjd ?? 'N/A',
              decimalSmall: true,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: _statTile(
              icon: Icons.groups_rounded,
              iconColor: const Color(0xFFF59E0B),
              label: '班级排名',
              value: rd?.bjpm ?? 'N/A',
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: _statTile(
              icon: Icons.emoji_events_rounded,
              iconColor: const Color(0xFF6366F1),
              label: '专业排名',
              value: rd?.pm ?? 'N/A',
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: _statTile(
              icon: Icons.menu_book_rounded,
              iconColor: const Color(0xFF10B981),
              label: '修读课程',
              value: rd?.countnum ?? 'N/A',
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: _statTile(
              icon: Icons.query_stats_rounded,
              iconColor: const Color(0xFF3B82F6),
              label: '查询次数',
              value: '${status.totalQueries}',
            ),
          ),
        ],
      ),
    );
  }

  Widget _statTile({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String value,
    bool decimalSmall = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    final valueStyle = TextStyle(
      fontSize: 68,
      fontWeight: FontWeight.w400,
      height: 1.0,
      letterSpacing: -1.5,
      color: cs.onSurface,
    );
    final dotIdx = decimalSmall ? value.indexOf('.') : -1;

    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 39.6, color: iconColor),
          const SizedBox(height: 10),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15.0,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const Spacer(),
          Align(
            alignment: Alignment.centerRight,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: dotIdx >= 0
                  ? Text.rich(
                      TextSpan(
                        style: valueStyle,
                        children: [
                          TextSpan(text: value.substring(0, dotIdx)),
                          TextSpan(
                            text: value.substring(dotIdx),
                            style: const TextStyle(fontSize: 34),
                          ),
                        ],
                      ),
                    )
                  // 超过 2 位数：首字保持原尺寸，其余数字缩小以适配卡片宽度
                  : value.length > 2
                  ? Text.rich(
                      TextSpan(
                        style: valueStyle,
                        children: [
                          TextSpan(text: value.substring(0, 1)),
                          TextSpan(
                            text: value.substring(1),
                            style: TextStyle(
                              fontSize: value.length >= 5 ? 32 : 42,
                            ),
                          ),
                        ],
                      ),
                    )
                  : Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: valueStyle,
                    ),
            ),
          ),
        ],
      ),
    );
  }
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
      borderRadius: BorderRadius.circular(6),
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
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
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
