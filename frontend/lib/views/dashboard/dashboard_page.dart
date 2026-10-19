import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
          padding: const EdgeInsets.all(28),
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
              const SizedBox(height: 6),
              Text(
                '实时监控成绩更新状态',
                style: TextStyle(
                  fontSize: 14,
                  color: colorScheme.onSurface.withValues(alpha: .5),
                ),
              ),
              const SizedBox(height: 28),
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

    return SizedBox(
      height: 88,
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 24),
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
      ),
    );
  }

  /// 「最新动态」卡：优先展示最近一次变动（通知模块生成的真实内容）；
  /// 无变动记录时回退显示最新一门成绩。
  Widget _buildLatestCard(AsyncValue<List<GradeCourse>> gradesAsync) {
    final cs = Theme.of(context).colorScheme;
    final settings = ref.read(settingsProvider);
    final subColor = cs.onSurface.withValues(alpha: .45);
    final tinyColor = cs.onSurface.withValues(alpha: .3);

    final change = _latestChange;

    String tagText;
    Color tagColor;
    String title;
    String detail;
    String at = '';

    if (change != null) {
      final raw = (change['title'] ?? '').toString();
      final idx = raw.indexOf('：');
      tagText = '最新变动';
      tagColor = AppTheme.success;
      title = idx >= 0
          ? raw.substring(idx + 1)
          : (raw.isEmpty ? '成绩与排名更新' : raw);
      final msg = (change['message'] ?? '').toString();
      detail = msg.isEmpty ? '详情见「成绩单」' : msg.replaceAll('\n', '　·　');
      at = (change['at'] ?? '').toString();
    } else {
      final latest = _latestCourse(gradesAsync.asData?.value);
      if (latest == null) {
        tagText = '暂无更新';
        tagColor = subColor;
        title = settings.username.isEmpty ? '请先在设置中配置账户' : '暂无成绩数据';
        detail = '完成监控配置后，成绩与排名变动会第一时间展示在这里';
      } else {
        tagText = '暂无更新 · 最新一门';
        tagColor = subColor;
        title = latest.kcname;
        detail = '期末 ${latest.cjxm3.isEmpty ? '-' : latest.cjxm3}　·　'
            '加权 ${latest.zcj.isEmpty ? '-' : latest.zcj}　·　'
            '绩点 ${latest.jd.isEmpty ? '-' : latest.jd}';
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
              Text(at, style: TextStyle(fontSize: 11.5, color: tinyColor)),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            title,
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
            detail,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, color: subColor, height: 1.6),
          ),
        ],
      ),
    );
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
              icon: Icons.manage_history_rounded,
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
      fontWeight: FontWeight.w600,
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
          Icon(icon, size: 22, color: iconColor),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withValues(alpha: .5),
            ),
          ),
          const Spacer(),
          Align(
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
                : Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: valueStyle,
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
