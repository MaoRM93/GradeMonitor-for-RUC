import 'package:flutter/material.dart';
import '../../core/network/api_client.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/toast_host.dart';
import '../../core/service/nav_signal.dart';

/// 仅在口令验证后的设置页显示；令牌只随单次 GitHub 请求提交，不落盘。
class DeveloperOptions extends StatefulWidget { const DeveloperOptions({super.key}); @override State<DeveloperOptions> createState() => _DeveloperOptionsState(); }
class _DeveloperOptionsState extends State<DeveloperOptions> {
  final _api = ApiClient(); final _token = TextEditingController(); final _title = TextEditingController(); final _body = TextEditingController(); final _tag = TextEditingController(text: '114.');
  final _interval = TextEditingController(text: '300');
  bool _busy = false;
  @override void dispose() { _token.dispose(); _title.dispose(); _body.dispose(); _tag.dispose(); _interval.dispose(); super.dispose(); }
  Future<void> _run(String action) async {
    setState(() => _busy = true);
    try { final r = await _api.developerConsole({'action': action, 'github_token': _token.text, 'title': _title.text, 'body': _body.text, 'tag': _tag.text}); if (mounted) ToastHost().show(r.data['message']?.toString() ?? '操作成功'); }
    catch (e) { if (mounted) ToastHost().show('控制台操作失败：$e'); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  Widget _button(String label, String action, {bool danger = false}) => OutlinedButton(onPressed: _busy ? null : () => _run(action), style: danger ? OutlinedButton.styleFrom(foregroundColor: AppTheme.error, side: BorderSide(color: AppTheme.error.withValues(alpha: .5))) : null, child: Text(label));
  Future<void> _local(String label, Future<dynamic> Function() action) async { try { final r = await action(); if (mounted) ToastHost().show('$label：${r.data['message'] ?? '操作成功'}'); } catch (e) { if (mounted) ToastHost().show('$label 失败：$e'); } }
  Future<void> _disableDeveloper() async { try { await _api.disableDeveloper(); developerOptionsEnabled.value = false; } catch (e) { if (mounted) ToastHost().show('关闭失败：$e'); } }
  @override Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [const Text('开发者选项', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)), const Spacer(), TextButton.icon(onPressed: _disableDeveloper, icon: const Icon(Icons.visibility_off_outlined, size: 17), label: const Text('关闭开发者选项'))]), const SizedBox(height: 12),
    GlassCard(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('本地工具', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)), const SizedBox(height: 10), Wrap(spacing: 8, runSpacing: 8, children: [OutlinedButton(onPressed: () => _local('立即查询', _api.queryOnce), child: const Text('立即查询')), OutlinedButton(onPressed: () => _local('测试通知', _api.sendTestNotification), child: const Text('测试通知')), OutlinedButton(onPressed: () => _local('打开数据目录', _api.openLogDir), child: const Text('打开数据目录')), OutlinedButton(onPressed: () => _local('清理缓存', _api.clearCache), child: const Text('清理缓存'))]), const SizedBox(height: 12), Row(children: [SizedBox(width: 120, child: TextField(controller: _interval, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '轮询秒数', border: OutlineInputBorder()))), const SizedBox(width: 8), OutlinedButton(onPressed: () => _local('设置间隔', () => _api.updateSettings({'interval_seconds': int.tryParse(_interval.text) ?? 300})), child: const Text('应用'))])])), const SizedBox(height: 16),
    GlassCard(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('控制台', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)), const SizedBox(height: 6),
      Text('使用具有 Releases 读写权限的 GitHub Fine-grained PAT。令牌不保存；发布后的客户端将在下一次远程检查时生效。', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .6))), const SizedBox(height: 14),
      TextField(controller: _token, obscureText: true, decoration: const InputDecoration(labelText: 'GitHub Fine-grained PAT', border: OutlineInputBorder())), const SizedBox(height: 10),
      TextField(controller: _title, decoration: const InputDecoration(labelText: '界面标题（可选）', border: OutlineInputBorder())), const SizedBox(height: 10),
      TextField(controller: _body, minLines: 3, maxLines: 6, decoration: const InputDecoration(labelText: '界面显示内容（支持 Markdown）', border: OutlineInputBorder())), const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        SizedBox(width: 120, child: TextField(controller: _tag, decoration: const InputDecoration(labelText: '广播标签', border: OutlineInputBorder()))),
        _button('发布用户通知', 'broadcast'), _button('发布蓝屏页面', 'blue'), _button('撤回蓝屏页面', 'clear_blue'), _button('发布红屏页面', 'red', danger: true), _button('撤回红屏页面', 'clear_red'), _button('远程禁用 114 广播', 'disable_114', danger: true), _button('恢复 114 广播', 'enable_114'),
      ]),
      const SizedBox(height: 12), const Text('说明：蓝屏与红屏使用独立的 developer-alert / service-suspension 控制通道。114 开关只停止旧普通广播，不影响它们。令牌不保存，只有拥有仓库 Releases 写权限的账号可以发布。', style: TextStyle(fontSize: 12)),
    ])),
  ]);
}
