import 'package:flutter/material.dart';

import '../../core/network/api_client.dart';
import '../../core/service/feature_gate_service.dart';
import '../../core/service/nav_signal.dart';
import '../../core/service/ui_prefs_service.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/toast_host.dart';

/// 本机调谐开关。它们与远程功能组一同显示在「功能遥测」中，
/// 但仍只写入本机的 `feature_flags.json`。
const List<String> kTuningFlags = <String>[
  'Enable_PYFA_EvyGrde', // 1.1
  'Show_Feature_0A1B', // 1.2
  'Enable_Feature_1A2C', // 1.3
  'Enable_Feature_2B3D', // 1.4
  'Disable_Flag_Ntce114', // 114 广播通道
];

/// 这些闸门是产品的安全/生存基础，只展示其状态，不能从面板下线。
const Set<String> kLockedGateIds = <String>{
  'Flag-1051',
  'Flag-1042',
  'Flag-1070',
  'Flag-1071',
  'Flag-1085',
  'Flag-1084',
  'Flag-1063',
  'Flag-1066',
  'Flag-1060',
  'Flag-1074',
  'Flag-1001',
};

// 「功能遥测」不再是 2.1–2.15 那排空开关：该卡已与「远程下发」合并，
// 直接渲染功能组注册表里的真实开关（Flag-1xxx），因此旧的
// kTelemetryFlags 常量与它的假按钮一并移除。后端 DEFAULT_FLAGS 里
// 那 15 个预留键仍被接受（未知键才报错），只是 UI 不再暴露。

/// 与后端 DEFAULT_FLAGS 对齐的初始值：首帧不至于把 1.4 画成"关"再跳成"开"。
const Map<String, bool> _kDefaultFlagStates = <String, bool>{
  'Enable_Feature_2B3D': true,
};

/// 仅在 GitHub 开发者身份验证通过后的设置页显示。
///
/// 这里的所有控件都只改**本机**状态（`feature_flags.json` / `feature_gates.json`），
/// 不持有任何能向仓库写入的令牌——远程下发走的是 Ed25519 签名块，
/// 只有掌握本机私钥的人才能签发。详见 docs/DEV_FLAGS_CONTRACT.md。
class DeveloperOptions extends StatefulWidget {
  const DeveloperOptions({super.key});

  @override
  State<DeveloperOptions> createState() => _DeveloperOptionsState();
}

class _DeveloperOptionsState extends State<DeveloperOptions> {
  final _api = ApiClient();
  late final TextEditingController _interval;
  final _noticeTitle = TextEditingController();
  final _noticeBody = TextEditingController();
  String? _noticeChannel;
  bool _sendingNotice = false;

  /// 开发者开关的本地镜像（键 → 状态）。点击时乐观更新，失败回滚。
  final Map<String, bool> _flags = Map<String, bool>.of(_kDefaultFlagStates);

  /// 功能组开关的本地镜像：Flag-1xxx 编号 → 当前生效状态。
  ///
  /// 与 [_flags] 是两套东西：那边是开发者调谐开关（写本机 `feature_flags.json`），
  /// 这边是所有客户端的功能组开关（本机值 + 远程签名指令的合并结果）。
  final Map<String, bool> _gateStates = <String, bool>{};

  /// 尚未发布的远程改动。面板点按只改这份草稿，绝不能先影响本机业务。
  final Map<String, bool> _pendingGates = <String, bool>{};

  /// 当前已应用的远程指令版本号（0 = 从未下发过）。
  int _remoteRev = 0;

  /// 正在签发/下发远程开关。
  bool _publishing = false;

  @override
  void initState() {
    super.initState();
    // 轮询秒数取上次保存的值，避免切走再回来又变回 300。
    _interval = TextEditingController(
      text: UiPrefsService.readPref(
        UiPrefsService.prefDevIntervalSeconds,
        fallback: '300',
      ),
    );
    _bootstrap();
  }

  @override
  void dispose() {
    _interval.dispose();
    _noticeTitle.dispose();
    _noticeBody.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await UiPrefsService.ensureLoaded();
    if (!mounted) return;
    final saved = UiPrefsService.readPref(
      UiPrefsService.prefDevIntervalSeconds,
      fallback: '300',
    );
    if (saved != null && saved.isNotEmpty && _interval.text != saved) {
      _interval.text = saved;
    }
    await _loadFlags();
    await _loadGates();
  }

  /// 拉一次全部开关状态；失败时保持当前镜像（不弹错，避免进页面就吵）。
  Future<void> _loadFlags() async {
    try {
      final r = await _api.getDeveloperFlags();
      final raw = (r.data is Map ? r.data['flags'] : null);
      if (!mounted || raw is! Map) return;
      setState(() {
        for (final entry in raw.entries) {
          if (entry.value is bool) {
            _flags[entry.key.toString()] = entry.value as bool;
          }
        }
      });
    } catch (_) {
      // 静默：开关面板打不开不影响其他开发者功能
    }
  }

  bool _flagOn(String name) => _flags[name] ?? false;

  /// 拉一次功能组开关注册表与当前生效值。
  Future<void> _loadGates() async {
    try {
      await FeatureGateService.instance.ensureLoaded(force: true);
      if (!mounted) return;
      setState(() {
        _gateStates
          ..clear()
          ..addAll(FeatureGateService.instance.states.value);
      });
    } catch (_) {
      // 静默：注册表拉不到时该卡显示为空，不影响其它开发者功能
    }
  }

  /// 切换某个功能组开关：只保存在发布草稿，Apply 成功前不写本机后端。
  Future<void> _toggleGate(String id) async {
    final next = !(_gateStates[id] ?? true);
    setState(() {
      _gateStates[id] = next;
      _pendingGates[id] = next;
    });
  }

  /// 签发远程功能开关指令。
  ///
  /// [push] 为 false 时后端只返回签名块、不推 GitHub —— 先人工核对内容，
  /// 确认无误再点 Apply。
  Future<void> _publishGates({required bool push}) async {
    setState(() => _publishing = true);
    try {
      final r = await _api.publishGates(
        gates: Map<String, bool>.from(_pendingGates),
        // 版本号只由后端在真正发布时分配；Sign 不应占用版本，也不应令
        // 下一次 Apply 因复用旧 rev 而收到 400。
        rev: 0,
        push: push,
      );
      if (!mounted) return;
      final data = r.data is Map ? r.data as Map : const {};
      final rev = data['rev'];
      if (push && rev is int) {
        setState(() => _remoteRev = rev);
        _pendingGates.clear();
        // 后端确认 GitHub 发布成功后才会写本机远程快照；此时刷新生效状态。
        await _loadGates();
      }
      if (push) {
        ToastHost().show(data['message']?.toString() ?? '已下发');
      } else {
        ToastHost().show('已生成签名块 rev=$rev');
      }
    } catch (e) {
      if (mounted) ToastHost().show('${push ? '下发' : '签发'}失败：$e');
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  /// 乐观切换 + 失败回滚。
  ///
  /// 刻意**不**在请求期间禁用整组按钮：开关是高频连点操作，禁用会让整排
  /// 按钮瞬间变灰再恢复（视觉闪动），比偶尔一次回滚更扰人。请求串行化由
  /// 后端原子写保证，前端只负责状态正确性。
  Future<void> _toggleFlag(String name) async {
    final next = !_flagOn(name);
    setState(() => _flags[name] = next);
    try {
      final r = await _api.setDeveloperFlag(name, next);
      final raw = (r.data is Map ? r.data['flags'] : null);
      if (!mounted || raw is! Map) return;
      setState(() {
        for (final entry in raw.entries) {
          if (entry.value is bool) {
            _flags[entry.key.toString()] = entry.value as bool;
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _flags[name] = !next); // 回滚
      ToastHost().show('开关保存失败：$e');
    }
  }

  Future<void> _local(String label, Future<dynamic> Function() action) async {
    try {
      final r = await action();
      final data = r.data;
      final message = (data is Map ? data['message'] : null)?.toString();
      if (mounted) ToastHost().show('$label：${message ?? '操作成功'}');
    } catch (e) {
      if (mounted) ToastHost().show('$label 失败：$e');
    }
  }

  /// 保存轮询秒数：同时写后端设置与本地偏好（切选项卡/重启都保留）。
  Future<void> _saveInterval() async {
    final seconds = int.tryParse(_interval.text.trim());
    if (seconds == null || seconds < 60 || seconds > 86400) {
      ToastHost().show('请输入 60 至 86400 之间的秒数');
      return;
    }
    try {
      await _api.updateSettings({'interval_seconds': seconds});
      await UiPrefsService.writePref(
        UiPrefsService.prefDevIntervalSeconds,
        '$seconds',
      );
      if (mounted) ToastHost().show('设置间隔：操作成功');
    } catch (e) {
      if (mounted) ToastHost().show('设置间隔失败：$e');
    }
  }

  /// 退出开发者模式：清除系统凭据存储里的 GitHub 令牌与身份。
  Future<void> _disableDeveloper() async {
    try {
      await _api.logoutDeveloper();
      await UiPrefsService.ensureLoaded();
      await UiPrefsService.writeBoolPref(
        UiPrefsService.prefDevPanelPinned,
        false,
      );
      developerOptionsEnabled.value = false;
    } catch (e) {
      if (mounted) ToastHost().show('退出失败: $e');
    }
  }

  bool get _noticeReady =>
      _noticeChannel != null &&
      _noticeBody.text.trim().isNotEmpty &&
      (_noticeChannel != 'Default_Notice' ||
          _noticeTitle.text.trim().isNotEmpty);

  Future<void> _sendNotice() async {
    if (!_noticeReady) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认发送通知？'),
        content: const Text('发送后，所有在线客户端会在下一次远程检查时收到此通知。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _sendingNotice = true);
    try {
      final r = await _api.publishDeveloperNotice(
        channel: _noticeChannel!,
        title: _noticeTitle.text.trim(),
        body: _noticeBody.text.trim(),
      );
      if (mounted)
        ToastHost().show(
          (r.data is Map ? r.data['message'] : null)?.toString() ?? '通知已发送',
        );
    } catch (e) {
      if (mounted) ToastHost().show('发送失败：$e');
    } finally {
      if (mounted) setState(() => _sendingNotice = false);
    }
  }

  Future<void> _previewNotice() async {
    if (!_noticeReady) return;
    final important = _noticeChannel == 'Important (BL)';
    final disabled = _noticeChannel == 'Disable (RE)';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: disabled
            ? Theme.of(ctx).colorScheme.errorContainer
            : important
            ? Theme.of(ctx).colorScheme.primaryContainer
            : null,
        title: Text(
          disabled
              ? '服务暂停'
              : important
              ? '重要通知'
              : _noticeTitle.text.trim(),
        ),
        content: Text(_noticeBody.text.trim()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // ---------- 按钮 ----------

  /// 单个开关按钮：药丸形、无填充、文本恒定，只有颜色变化。
  ///
  /// 开启 = AppTheme.success（绿）、关闭 = AppTheme.error（红），
  /// 边框与文字同色。
  Widget _toggleButton({
    required bool on,
    required String label,
    VoidCallback? onTap,
    bool locked = false,
  }) {
    final color = locked
        ? Theme.of(context).colorScheme.onSurface.withValues(alpha: .28)
        : on
        ? AppTheme.success
        : AppTheme.error;
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        backgroundColor: Colors.transparent,
        side: BorderSide(color: color),
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
        shape: const StadiumBorder(),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _flagButton(String name, String label) => _toggleButton(
    on: _flagOn(name),
    label: label,
    onTap: () => _toggleFlag(name),
  );

  Widget _gateButton(String id, String label) => _toggleButton(
    on: _gateStates[id] ?? true,
    label: label,
    locked: kLockedGateIds.contains(id),
    onTap: kLockedGateIds.contains(id) ? null : () => _toggleGate(id),
  );

  /// 「功能遥测」卡：58 个功能组开关 + Sign / Reload / Apply。
  ///
  /// 点按只编辑远程草稿；Sign 只预览签名，Apply 成功后才推送并刷新生效值。
  Widget _gateCardBody() {
    final registry = FeatureGateService.instance.registry.value;
    // 58 个功能组平铺会糊成一片，按注册表自带的 group 分段渲染。
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final item in registry) {
      final group = item['group']?.toString() ?? '未分组';
      grouped.putIfAbsent(group, () => <Map<String, dynamic>>[]).add(item);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_remoteRev > 0)
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              'rev $_remoteRev',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: .6),
              ),
            ),
          ),
        if (_remoteRev > 0) const SizedBox(height: 8),
        Text(
          '本机功能 Flag',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: .62),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < kTuningFlags.length; i++)
              _flagButton(kTuningFlags[i], 'Flag-${i + 1}'),
          ],
        ),
        const SizedBox(height: 14),
        if (registry.isEmpty)
          const Text('功能组注册表未加载', style: TextStyle(fontSize: 12))
        else
          for (final entry in grouped.entries) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in entry.value)
                  _gateButton(
                    item['id']?.toString() ?? '',
                    item['id']?.toString() ?? '',
                  ),
              ],
            ),
            const SizedBox(height: 6),
          ],
        // 与最后一行按钮之间留出更大的行距，避免误触。
        const SizedBox(height: 22),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _actionButton('Sign', () => _publishGates(push: false)),
            const SizedBox(width: 8),
            _actionButton('Reload', _loadGates),
            const SizedBox(width: 8),
            _actionButton(
              'Apply',
              () => _publishGates(push: true),
              icon: Icons.check_rounded,
              destructive: true,
            ),
          ],
        ),
      ],
    );
  }

  /// 填充色动作按钮（Sign / Reload / Apply），药丸形。
  Widget _actionButton(
    String label,
    VoidCallback onTap, {
    IconData? icon,
    bool destructive = false,
  }) {
    return FilledButton(
      onPressed: _publishing ? null : onTap,
      style: FilledButton.styleFrom(
        backgroundColor: destructive
            ? Theme.of(context).colorScheme.error
            : null,
        foregroundColor: destructive
            ? Theme.of(context).colorScheme.onError
            : null,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 0),
        shape: const StadiumBorder(),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      child: icon == null
          ? Text(label)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 17),
                const SizedBox(width: 6),
                Text(label),
              ],
            ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Icon(Icons.code_rounded, size: 23),
          const SizedBox(width: 10),
          const Text(
            '开发者选项',
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: _disableDeveloper,
            icon: const Icon(Icons.visibility_off_outlined, size: 17),
            label: const Text('关闭开发者选项'),
          ),
        ],
      ),
      const SizedBox(height: 12),
      _DeveloperSectionTitle(title: '功能遥测', icon: Icons.hub_rounded),
      const SizedBox(height: 12),
      GlassCard(padding: const EdgeInsets.all(20), child: _gateCardBody()),
      const SizedBox(height: 24),
      _DeveloperSectionTitle(title: '广播通知', icon: Icons.campaign_outlined),
      const SizedBox(height: 12),
      GlassCard(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              children: ['Default_Notice', 'Important (BL)', 'Disable (RE)']
                  .map(
                    (channel) => ChoiceChip(
                      label: Text(channel),
                      selected: _noticeChannel == channel,
                      onSelected: (v) => setState(() {
                        _noticeChannel = v ? channel : null;
                        if (channel != 'Default_Notice') _noticeTitle.clear();
                      }),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _noticeTitle,
              enabled: _noticeChannel == 'Default_Notice',
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noticeBody,
              enabled: _noticeChannel != null,
              onChanged: (_) => setState(() {}),
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(labelText: 'Body'),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  onPressed: _noticeReady && !_sendingNotice
                      ? _previewNotice
                      : null,
                  child: const Text('Preview'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _noticeReady && !_sendingNotice
                      ? _sendNotice
                      : null,
                  icon: const Icon(Icons.send_rounded, size: 17),
                  label: const Text('Send'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 24),
      _DeveloperSectionTitle(title: '本地工具', icon: Icons.handyman_rounded),
      const SizedBox(height: 12),
      GlassCard(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _toolButton('立即查询', () => _local('立即查询', _api.queryOnce)),
                _toolButton(
                  '测试通知',
                  () => _local('测试通知', _api.sendTestNotification),
                ),
                _toolButton('打开数据目录', () => _local('打开数据目录', _api.openLogDir)),
                _toolButton('清理缓存', () => _local('清理缓存', _api.clearCache)),
                _toolButton(
                  '清除所有数据',
                  () => _local('清除所有数据', _api.clearAllData),
                  icon: Icons.close_rounded,
                  destructive: true,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 140,
                  child: SizedBox(
                    height: 36,
                    child: TextField(
                      controller: _interval,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _toolButton('应用', _saveInterval),
              ],
            ),
          ],
        ),
      ),
    ],
  );

  /// 本地工具按钮：药丸形、无填充、主题色。
  Widget _toolButton(
    String label,
    VoidCallback onTap, {
    IconData? icon,
    bool destructive = false,
  }) {
    final error = Theme.of(context).colorScheme.error;
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: destructive
            ? Theme.of(context).colorScheme.onError
            : null,
        backgroundColor: destructive ? error : null,
        side: destructive ? BorderSide(color: error) : null,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
        shape: const StadiumBorder(),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      child: icon == null
          ? Text(label)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 17),
                const SizedBox(width: 6),
                Text(label),
              ],
            ),
    );
  }
}

class _DeveloperSectionTitle extends StatelessWidget {
  const _DeveloperSectionTitle({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 20, color: colorScheme.primary),
        const SizedBox(width: 10),
        Text(
          title,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurface,
          ),
        ),
      ],
    );
  }
}
