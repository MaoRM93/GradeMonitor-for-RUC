import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/monitor_provider.dart';
import '../../widgets/glass_card.dart';

/// 开发者工具箱页面
class DevToolsPage extends ConsumerStatefulWidget {
  const DevToolsPage({super.key});

  @override
  ConsumerState<DevToolsPage> createState() => _DevToolsPageState();
}

class _DevToolsPageState extends ConsumerState<DevToolsPage> {
  String? _resultMsg;
  bool _loading = false;

  Future<void> _run(String label, Future<dynamic> Function() action) async {
    setState(() {
      _loading = true;
      _resultMsg = null;
    });
    try {
      final resp = await action();
      final data = resp.data as Map<String, dynamic>;
      setState(() {
        _resultMsg = '[$label] ${data['message'] ?? '操作成功'}';
      });
    } catch (e) {
      setState(() {
        _resultMsg = '[$label] 操作失败: $e';
      });
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final api = ref.read(apiClientProvider);

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '开发者工具箱',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '手动控制与调试工具',
                style: TextStyle(
                  fontSize: 14,
                  color: colorScheme.onSurface.withValues(alpha: .5),
                ),
              ),
              const SizedBox(height: 28),

              // 一键操作网格
              GlassCard(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '一键操作区',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        _DevButton(
                          icon: Icons.rocket_launch_rounded,
                          label: '立即查询',
                          description: '无视定时器，立即请求一次 API',
                          color: colorScheme.primary,
                          onTap: _loading
                              ? null
                              : () => _run('立即查询', () => api.queryOnce()),
                        ),
                        _DevButton(
                          icon: Icons.notifications_active_rounded,
                          label: '发送测试通知',
                          description: '触发 /api/notification/test',
                          color: AppTheme.warning,
                          onTap: _loading
                              ? null
                              : () => _run(
                                  '测试通知',
                                  () => api.sendTestNotification(),
                                ),
                        ),
                        _DevButton(
                          icon: Icons.folder_open_rounded,
                          label: '打开数据目录',
                          description: '调用 Finder 打开数据路径',
                          color: AppTheme.primarySky,
                          onTap: _loading
                              ? null
                              : () => _run('打开目录', () => api.openLogDir()),
                        ),
                        _DevButton(
                          icon: Icons.cleaning_services_rounded,
                          label: '清理数据缓存',
                          description:
                              '清理 local_grades.json 与 local_ranks.json',
                          color: Colors.orange,
                          onTap: _loading
                              ? null
                              : () => _run('清理缓存', () => api.clearCache()),
                        ),
                        _DevButton(
                          icon: Icons.dangerous_rounded,
                          label: '重置所有数据',
                          description: '重置所有缓存与设置',
                          color: AppTheme.error,
                          onTap: _loading
                              ? null
                              : () => showDialog(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('确认重置'),
                                    content: const Text(
                                      '此操作将清除所有缓存与设置数据，不可恢复。确定继续吗？',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(ctx),
                                        child: const Text('取消'),
                                      ),
                                      FilledButton(
                                        onPressed: () {
                                          Navigator.pop(ctx);
                                          _run(
                                            '重置数据',
                                            () => api.clearAllData(),
                                          );
                                        },
                                        style: FilledButton.styleFrom(
                                          backgroundColor: AppTheme.error,
                                        ),
                                        child: const Text('确认重置'),
                                      ),
                                    ],
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // 结果输出区
              if (_resultMsg != null || _loading)
                GlassCard(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_loading)
                        const Padding(
                          padding: EdgeInsets.only(right: 10),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      else
                        Icon(
                          _resultMsg!.contains('失败')
                              ? Icons.error_outline_rounded
                              : Icons.check_circle_outline_rounded,
                          size: 18,
                          color: _resultMsg!.contains('失败')
                              ? AppTheme.error
                              : AppTheme.success,
                        ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _loading ? '处理中...' : _resultMsg!,
                          style: TextStyle(
                            fontSize: 13,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              const SizedBox(height: 28),

              // macOS 原生提示
              GlassCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 16,
                      color: colorScheme.primary.withValues(alpha: .7),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '提示: 如需使用系统托盘图标，请确保 macOS 已授予辅助功能权限。',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurface.withValues(alpha: .5),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

/// 开发者操作按钮
class _DevButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String description;
  final Color color;
  final VoidCallback? onTap;

  const _DevButton({
    required this.icon,
    required this.label,
    required this.description,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;

    return SizedBox(
      width: 170,
      child: Material(
        color: enabled
            ? color.withValues(alpha: .08)
            : colorScheme.onSurface.withValues(alpha: .05),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: enabled
                      ? color
                      : colorScheme.onSurface.withValues(alpha: .2),
                ),
                const SizedBox(height: 10),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: enabled
                        ? colorScheme.onSurface
                        : colorScheme.onSurface.withValues(alpha: .25),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 10,
                    color: colorScheme.onSurface.withValues(alpha: .35),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
