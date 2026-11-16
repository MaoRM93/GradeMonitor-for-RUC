import 'package:flutter/material.dart';

import '../../core/network/api_client.dart';
import '../../widgets/toast_host.dart';

/// 移动端通知转发配置。接收地址只写入本机后端，加载时不会回显。
class NotificationForwardersPage extends StatefulWidget {
  const NotificationForwardersPage({super.key});

  @override
  State<NotificationForwardersPage> createState() => _NotificationForwardersPageState();
}

class _NotificationForwardersPageState extends State<NotificationForwardersPage> {
  final _api = ApiClient();
  final _barkUrl = TextEditingController();
  final _meowNickname = TextEditingController();
  final _ntfyServer = TextEditingController(text: 'https://ntfy.sh');
  final _ntfyTopic = TextEditingController();
  bool _bark = false, _meow = false, _ntfy = false, _loading = true, _saving = false;
  bool _barkConfigured = false, _meowConfigured = false, _ntfyConfigured = false;

  @override
  void initState() { super.initState(); _load(); }
  @override
  void dispose() { _barkUrl.dispose(); _meowNickname.dispose(); _ntfyServer.dispose(); _ntfyTopic.dispose(); super.dispose(); }

  Future<void> _load() async {
    try {
      final d = (await _api.getNotificationForwarders()).data as Map;
      final bark = d['bark'] as Map? ?? {}, meow = d['meow'] as Map? ?? {}, ntfy = d['ntfy'] as Map? ?? {};
      if (!mounted) return;
      setState(() {
        _bark = bark['enabled'] == true; _barkConfigured = bark['configured'] == true;
        _meow = meow['enabled'] == true; _meowConfigured = meow['configured'] == true;
        _ntfy = ntfy['enabled'] == true; _ntfyConfigured = ntfy['configured'] == true;
        _ntfyServer.text = ntfy['server']?.toString() ?? 'https://ntfy.sh';
        _loading = false;
      });
    } catch (_) { if (mounted) setState(() => _loading = false); }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _api.updateNotificationForwarders({
        'bark': {'enabled': _bark, 'url': _barkUrl.text.trim()},
        'meow': {'enabled': _meow, 'nickname': _meowNickname.text.trim()},
        'ntfy': {'enabled': _ntfy, 'server': _ntfyServer.text.trim(), 'topic': _ntfyTopic.text.trim()},
      });
      await _load();
      if (mounted) ToastHost().show('通知转发设置已保存');
    } catch (e) { if (mounted) ToastHost().show('保存失败：$e'); }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _test(String channel) async {
    try {
      final data = (await _api.testNotificationForwarder(channel)).data as Map;
      if (mounted) ToastHost().show('${channel.toUpperCase()} 测试：${data['message']}');
    } catch (e) { if (mounted) ToastHost().show('测试失败：$e'); }
  }

  Widget _channel({required String title, required String subtitle, required IconData icon, required bool enabled, required ValueChanged<bool> onChanged, required bool configured, required List<Widget> fields, required String id}) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Icon(icon, color: cs.primary), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)), Text(subtitle, style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: .58)))])), Switch(value: enabled, onChanged: onChanged)]),
          const SizedBox(height: 14), ...fields,
          const SizedBox(height: 8),
          Row(children: [Text(configured ? '已保存接收配置' : '尚未保存接收配置', style: TextStyle(fontSize: 12, color: configured ? Colors.green : cs.onSurface.withValues(alpha: .45))), const Spacer(), OutlinedButton.icon(onPressed: () => _test(id), icon: const Icon(Icons.send_outlined, size: 16), label: const Text('测试通道'))]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Scaffold(body: SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(28, 44, 28, 40), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('通知转发', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Text('成绩或排名变化时，程序会先发送本机通知，再异步发送到已启用的移动端通道。通道失败不会影响成绩监控。', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .65))),
      const SizedBox(height: 20),
      _channel(title: 'Bark · iPhone / iPad', subtitle: '安装 Bark 后复制首页的推送地址；建议仅填个人设备地址。', icon: Icons.phone_iphone_rounded, enabled: _bark, onChanged: (v) => setState(() => _bark = v), configured: _barkConfigured, id: 'bark', fields: [TextField(controller: _barkUrl, obscureText: true, decoration: const InputDecoration(labelText: 'Bark 推送地址', hintText: 'https://api.day.app/你的设备密钥', border: OutlineInputBorder()))]),
      _channel(title: 'MeoW · HarmonyOS', subtitle: '在鸿蒙设备安装并注册 MeoW，填写注册昵称；建议使用简洁通知模式。', icon: Icons.devices_other_rounded, enabled: _meow, onChanged: (v) => setState(() => _meow = v), configured: _meowConfigured, id: 'meow', fields: [TextField(controller: _meowNickname, obscureText: true, decoration: const InputDecoration(labelText: 'MeoW 昵称', border: OutlineInputBorder()))]),
      _channel(title: 'ntfy · Android', subtitle: '在 Android 安装 ntfy，订阅随机 Topic。官方服务免费；Topic 应足够随机且不要分享。', icon: Icons.android_rounded, enabled: _ntfy, onChanged: (v) => setState(() => _ntfy = v), configured: _ntfyConfigured, id: 'ntfy', fields: [TextField(controller: _ntfyServer, decoration: const InputDecoration(labelText: 'ntfy 服务器', border: OutlineInputBorder())), const SizedBox(height: 10), TextField(controller: _ntfyTopic, obscureText: true, decoration: const InputDecoration(labelText: 'Topic', hintText: '例如 grade_随机长字符串', border: OutlineInputBorder()))]),
      const SizedBox(height: 8),
      Card(color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: .42), child: const Padding(padding: EdgeInsets.all(16), child: Text('使用方法\n1. 在手机端完成对应 App 的首次设置并允许通知。\n2. 填写接收地址/昵称/Topic，开启开关后点“保存”。\n3. 点击“测试通道”，确认手机收到 GradeMonitor 测试通知。\n4. 之后每次真实成绩或排名变化都会自动转发。'))),
      const SizedBox(height: 18), Align(alignment: Alignment.centerRight, child: FilledButton.icon(onPressed: _saving ? null : _save, icon: const Icon(Icons.save_outlined), label: Text(_saving ? '保存中…' : '保存设置'))),
    ]))));
  }
}
