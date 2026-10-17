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
  String _selectedSemester = '全部';
  bool _isQuerying = false;
  bool _isTogglingMonitor = false;
  bool _showDetailData = true;

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
              _buildMonitorCard(monitorState, rankAsync),
              const SizedBox(height: 20),
              _buildGradesSection(gradesAsync),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMonitorCard(
    MonitorStatus status,
    AsyncValue<RankData?> rankAsync,
  ) {
    final colorScheme = Theme.of(context).colorScheme;

    return GlassCard(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PulsingStatusDot(active: status.isRunning),
              const SizedBox(width: 12),
              Text(
                status.isRunning ? '监控运行中' : '监控已停止',
                style: TextStyle(
                  fontSize: 18,
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
              const SizedBox(width: 8),
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
          const SizedBox(height: 16),
          Row(
            children: [
              _StatItem(
                icon: Icons.refresh_rounded,
                label: '累计查询',
                value: '${status.totalQueries} 次',
              ),
              const SizedBox(width: 24),
              _StatItem(
                icon: Icons.timer_rounded,
                label: '轮询间隔',
                value: '${status.intervalSeconds}s',
              ),
              const SizedBox(width: 24),
              if (_showDetailData)
                rankAsync.when(
                  data: (rd) => rd != null
                      ? Expanded(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              _RankChip(
                                'GPA：${rd.pjxfjd}',
                                const Color(0xFF8B5CF6),
                              ),
                              const SizedBox(width: 8),
                              _RankChip(
                                '班级排名：${rd.bjpm}',
                                const Color(0xFFF59E0B),
                              ),
                              const SizedBox(width: 8),
                              _RankChip(
                                '专业排名：${rd.pm}',
                                const Color(0xFF6366F1),
                              ),
                              const SizedBox(width: 8),
                              _RankChip(
                                '修读课程数量：${rd.countnum}',
                                const Color(0xFF10B981),
                              ),
                            ],
                          ),
                        )
                      : const SizedBox.shrink(),
                  loading: () => const SizedBox.shrink(),
                  error: (_, __) => const SizedBox.shrink(),
                )
              else
                const Spacer(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGradesSection(AsyncValue<List<GradeCourse>> gradesAsync) {
    final colorScheme = Theme.of(context).colorScheme;
    final settings = ref.read(settingsProvider);
    final hideUnknown = settings.hideUnknownCourses;

    return gradesAsync.when(
      data: (grades) {
        var display = hideUnknown
            ? grades.where((g) => g.kcname != '未知课程').toList()
            : grades;
        if (display.isEmpty) {
          // 仅在没有数据且没有配置凭据时提示
          if (settings.username.isEmpty) {
            return GlassCard(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(40),
                  child: Text(
                    '请先在「设置」中登录并保存凭据',
                    style: TextStyle(
                      fontSize: 14,
                      color: colorScheme.onSurface.withValues(alpha: .35),
                    ),
                  ),
                ),
              ),
            );
          }
          return GlassCard(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(40),
                child: Text(
                  '暂无成绩数据',
                  style: TextStyle(
                    fontSize: 14,
                    color: colorScheme.onSurface.withValues(alpha: .35),
                  ),
                ),
              ),
            ),
          );
        }

        final semesters = <String>{'全部'};
        for (final g in display) {
          if (g.xnxq.isNotEmpty) semesters.add(g.xnxq);
        }
        final semesterList = semesters.toList()..sort((a, b) => b.compareTo(a));
        final filtered = _selectedSemester == '全部'
            ? display
            : display.where((g) => g.xnxq == _selectedSemester).toList();

        return GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.auto_stories_rounded,
                    size: 20,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '成绩列表',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  const Text('学期：', style: TextStyle(fontSize: 12)),
                  DropdownButton<String>(
                    value: semesterList.contains(_selectedSemester)
                        ? _selectedSemester
                        : '全部',
                    items: semesterList
                        .map(
                          (s) => DropdownMenuItem(
                            value: s,
                            child: Text(
                              s,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) =>
                        setState(() => _selectedSemester = v ?? '全部'),
                    underline: const SizedBox(),
                    isDense: true,
                  ),
                  const SizedBox(width: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: 24,
                        child: Checkbox(
                          value: _showDetailData,
                          onChanged: (v) =>
                              setState(() => _showDetailData = v ?? true),
                        ),
                      ),
                      const Text('显示完整成绩', style: TextStyle(fontSize: 11)),
                    ],
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${filtered.length}门',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurface.withValues(alpha: .5),
                    ),
                  ),
                ],
              ),
              if (_showDetailData) ...[
                const SizedBox(height: 10),
                LayoutBuilder(
                  builder: (_, constraints) {
                    return SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minWidth: constraints.maxWidth,
                        ),
                        child: DataTable(
                          headingRowColor: WidgetStateProperty.all(
                            colorScheme.surfaceContainerHighest.withValues(
                              alpha: .3,
                            ),
                          ),
                          headingTextStyle: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: colorScheme.onSurface,
                          ),
                          dataTextStyle: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurface,
                          ),
                          columnSpacing: constraints.maxWidth > 600 ? 24 : 14,
                          horizontalMargin: 10,
                          columns: const [
                            DataColumn(label: Center(child: Text('学期'))),
                            DataColumn(label: Center(child: Text('课程'))),
                            DataColumn(
                              label: Center(child: Text('平时成绩')),
                              numeric: true,
                            ),
                            DataColumn(
                              label: Center(child: Text('期末成绩')),
                              numeric: true,
                            ),
                            DataColumn(
                              label: Center(child: Text('加权成绩')),
                              numeric: true,
                            ),
                            DataColumn(
                              label: Center(child: Text('绩点')),
                              numeric: true,
                            ),
                            DataColumn(
                              label: Center(child: Text('平均绩点')),
                              numeric: true,
                            ),
                          ],
                          rows: filtered
                              .map(
                                (course) => DataRow(
                                  cells: [
                                    DataCell(
                                      Center(
                                        child: Text(
                                          course.xnxq.isEmpty
                                              ? '-'
                                              : course.xnxq,
                                        ),
                                      ),
                                    ),
                                    DataCell(
                                      Center(
                                        child: ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            maxWidth: 150,
                                          ),
                                          child: Text(
                                            course.kcname,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ),
                                    ),
                                    DataCell(
                                      Center(
                                        child: Text(
                                          course.cjxm1.isEmpty
                                              ? '-'
                                              : course.cjxm1,
                                        ),
                                      ),
                                    ),
                                    DataCell(
                                      Center(
                                        child: Text(
                                          course.cjxm3.isEmpty
                                              ? '-'
                                              : course.cjxm3,
                                        ),
                                      ),
                                    ),
                                    DataCell(
                                      Center(
                                        child: Text(
                                          course.zcj.isEmpty ? '-' : course.zcj,
                                        ),
                                      ),
                                    ),
                                    DataCell(
                                      Center(
                                        child: Text(
                                          course.jd.isEmpty ? '-' : course.jd,
                                        ),
                                      ),
                                    ),
                                    DataCell(
                                      Center(
                                        child: Text(
                                          course.avgGpa,
                                          style: _gpaStyle(
                                            course.avgGpa,
                                            colorScheme,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
        );
      },
      loading: () => const GlassCard(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(40),
            child: CircularProgressIndicator(),
          ),
        ),
      ),
      error: (_, __) => GlassCard(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: Text(
              '加载成绩失败',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
          ),
        ),
      ),
    );
  }

  TextStyle _gpaStyle(String gpa, ColorScheme cs) {
    final v = double.tryParse(gpa);
    Color c = cs.onSurface;
    if (v != null) {
      if (v >= 4.0)
        c = const Color(0xFF10B981);
      else if (v >= 3.3)
        c = const Color(0xFF3B82F6);
      else if (v >= 2.0)
        c = const Color(0xFFF59E0B);
      else
        c = const Color(0xFFEF4444);
    }
    return TextStyle(fontWeight: FontWeight.w700, color: c);
  }
}

class _RankChip extends StatelessWidget {
  final String text;
  final Color color;
  const _RankChip(this.text, this.color);
  @override
  Widget build(BuildContext c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
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

class _StatItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _StatItem({
    required this.icon,
    required this.label,
    required this.value,
  });
  @override
  Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: cs.onSurface.withValues(alpha: .35)),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurface.withValues(alpha: .35),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
