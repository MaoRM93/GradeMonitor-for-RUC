import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/network/api_client.dart';
import '../../widgets/toast_host.dart';

/// 收件凭据只保留在本机后端；本页在当前应用会话内保留已保存草稿。
class NotificationForwardersPage extends StatefulWidget {
  const NotificationForwardersPage({super.key});

  @override
  State<NotificationForwardersPage> createState() =>
      _NotificationForwardersPageState();
}

class _NotificationForwardersPageState
    extends State<NotificationForwardersPage> {
  static final Map<String, Map<String, String>> _savedDrafts = {};
  final _api = ApiClient();
  final _barkUrl = TextEditingController();
  final _meowNickname = TextEditingController();
  final _ntfyServer = TextEditingController(text: 'https://ntfy.sh');
  final _ntfyTopic = TextEditingController();
  final Set<String> _dirty = {};
  final Map<String, String> _saveLabels = {};
  String? _savingChannel;
  bool _bark = false, _meow = false, _ntfy = false, _loading = true;
  bool _barkConfigured = false,
      _meowConfigured = false,
      _ntfyConfigured = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _barkUrl.dispose();
    _meowNickname.dispose();
    _ntfyServer.dispose();
    _ntfyTopic.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = (await _api.getNotificationForwarders()).data as Map;
      final bark = d['bark'] as Map? ?? {},
          meow = d['meow'] as Map? ?? {},
          ntfy = d['ntfy'] as Map? ?? {};
      if (!mounted) return;
      setState(() {
        _bark = bark['enabled'] == true;
        _barkConfigured = bark['configured'] == true;
        _meow = meow['enabled'] == true;
        _meowConfigured = meow['configured'] == true;
        _ntfy = ntfy['enabled'] == true;
        _ntfyConfigured = ntfy['configured'] == true;
        _barkUrl.text = _savedDrafts['bark']?['url'] ?? '';
        _meowNickname.text = _savedDrafts['meow']?['nickname'] ?? '';
        _ntfyServer.text =
            _savedDrafts['ntfy']?['server'] ??
            ntfy['server']?.toString() ??
            'https://ntfy.sh';
        _ntfyTopic.text = _savedDrafts['ntfy']?['topic'] ?? '';
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _markDirty(String channel) => setState(() {
    _dirty.add(channel);
    _saveLabels.remove(channel);
  });

  Future<void> _saveChannel(String channel) async {
    setState(() {
      _savingChannel = channel;
      _saveLabels.remove(channel);
    });
    final value = switch (channel) {
      'bark' => {'enabled': _bark, 'url': _barkUrl.text.trim()},
      'meow' => {'enabled': _meow, 'nickname': _meowNickname.text.trim()},
      _ => {
        'enabled': _ntfy,
        'server': _ntfyServer.text.trim(),
        'topic': _ntfyTopic.text.trim(),
      },
    };
    try {
      final response = await _api.updateNotificationForwarders({
        channel: value,
      });
      final data = response.data as Map;
      final configured =
          ((data['forwarders'] as Map?)?[channel] as Map?)?['configured'] ==
          true;
      if (!mounted) return;
      setState(() {
        if (channel == 'bark') _barkConfigured = configured;
        if (channel == 'meow') _meowConfigured = configured;
        if (channel == 'ntfy') _ntfyConfigured = configured;
        _savedDrafts[channel] = Map<String, String>.from(
          value.map((k, v) => MapEntry(k, '$v')),
        );
        _dirty.remove(channel);
        _saveLabels[channel] = '已保存';
      });
    } catch (_) {
      if (mounted) setState(() => _saveLabels[channel] = '保存失败');
    } finally {
      if (mounted) setState(() => _savingChannel = null);
    }
  }

  Future<void> _test(String channel) async {
    try {
      final data = (await _api.testNotificationForwarder(channel)).data as Map;
      if (mounted)
        ToastHost().show('${channel.toUpperCase()} 测试：${data['message']}');
    } catch (e) {
      if (mounted) ToastHost().show('测试失败：$e');
    }
  }

  Future<void> _openLink(String url) async {
    try {
      if (Platform.isMacOS)
        await Process.start('open', [url]);
      else if (Platform.isWindows)
        await Process.start('cmd', ['/c', 'start', '', url]);
      else
        await Process.start('xdg-open', [url]);
    } catch (_) {
      if (mounted) ToastHost().show('无法打开链接');
    }
  }

  InputDecoration _field(String label, String? hint) => InputDecoration(
    labelText: label,
    hintText: hint,
    filled: true,
    fillColor: const Color(0xFFD4E3F6),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(999),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(999),
      borderSide: BorderSide.none,
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(999),
      borderSide: BorderSide.none,
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
  );

  Widget _link(String text, String url) => InkWell(
    onTap: () => _openLink(url),
    child: Text(
      '$text ↗',
      style: TextStyle(
        fontSize: 12,
        color: Theme.of(context).colorScheme.primary,
        decoration: TextDecoration.underline,
        decorationColor: Theme.of(context).colorScheme.primary,
      ),
    ),
  );

  Widget _channel({
    required String title,
    required Widget icon,
    required bool enabled,
    required bool configured,
    required String id,
    required ValueChanged<bool> onChanged,
    required List<Widget> fields,
    required Widget description,
  }) {
    final cs = Theme.of(context).colorScheme;
    final canTest =
        configured && !_dirty.contains(id) && _savingChannel == null;
    final isSaving = _savingChannel == id;
    final label = isSaving ? '保存中…' : (_saveLabels[id] ?? '保存此通道');
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? cs.surface
            : Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .07),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(width: 26, height: 26, child: Center(child: icon)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 17,
                  ),
                ),
              ),
              Switch(
                value: enabled,
                onChanged: (value) {
                  onChanged(value);
                  _markDirty(id);
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...fields,
          const SizedBox(height: 10),
          DefaultTextStyle(
            style: TextStyle(
              fontSize: 12,
              height: 1.55,
              color: cs.onSurface.withValues(alpha: .63),
            ),
            child: description,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              FilledButton.icon(
                onPressed: isSaving ? null : () => _saveChannel(id),
                style: _saveLabels[id] == '已保存'
                    ? FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF16A34A),
                      )
                    : _saveLabels[id] == '保存失败'
                    ? FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFDC2626),
                      )
                    : null,
                icon: Icon(
                  _saveLabels[id] == '已保存'
                      ? Icons.check_rounded
                      : _saveLabels[id] == '保存失败'
                      ? Icons.close_rounded
                      : Icons.save_rounded,
                  size: 17,
                ),
                label: Text(label),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: canTest ? () => _test(id) : null,
                icon: const Icon(Icons.send_outlined, size: 16),
                label: const Text('测试通道'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 44, 28, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '通知转发',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 20),
              _channel(
                title: 'Bark',
                icon: SvgPicture.asset(
                  'assets/Apple_Logo_Blue.svg',
                  colorFilter: ColorFilter.mode(cs.primary, BlendMode.srcIn),
                ),
                enabled: _bark,
                configured: _barkConfigured,
                id: 'bark',
                onChanged: (v) => setState(() => _bark = v),
                fields: [
                  TextField(
                    controller: _barkUrl,
                    obscureText: true,
                    onChanged: (_) => _markDirty('bark'),
                    decoration: _field('地址和 Key', 'https://api.day.app/你的设备密钥'),
                  ),
                ],
                description: const Text(
                  '适用于 iPhone 和 iPad 端，请您在 App Store 中下载 Bark 软件，授予其适当权限，并点击服务器页面复制按钮右侧的向下箭头，复制地址和Key，将得到的内容粘贴到本程序上面的文本框。',
                ),
              ),
              _channel(
                title: 'Meow',
                icon: SvgPicture.asset(
                  'assets/nearlink.svg',
                  colorFilter: ColorFilter.mode(cs.primary, BlendMode.srcIn),
                ),
                enabled: _meow,
                configured: _meowConfigured,
                id: 'meow',
                onChanged: (v) => setState(() => _meow = v),
                fields: [
                  TextField(
                    controller: _meowNickname,
                    obscureText: true,
                    onChanged: (_) => _markDirty('meow'),
                    decoration: _field('昵称', null),
                  ),
                ],
                description: const Text(
                  '适用于 HarmonyOS 端，请您在 App Gallery / 应用市场 中下载 Meow 应用，授予其适当的权限，并将其昵称复制到本程序上面的文本框。',
                ),
              ),
              _channel(
                title: 'ntfy',
                icon: Icon(Icons.android_rounded, color: cs.primary, size: 26),
                enabled: _ntfy,
                configured: _ntfyConfigured,
                id: 'ntfy',
                onChanged: (v) => setState(() => _ntfy = v),
                fields: [
                  TextField(
                    controller: _ntfyServer,
                    onChanged: (_) => _markDirty('ntfy'),
                    decoration: _field('服务器', null),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _ntfyTopic,
                    obscureText: true,
                    onChanged: (_) => _markDirty('ntfy'),
                    decoration: _field('Topic', '例如 grade_随机长字符串'),
                  ),
                ],
                description: Wrap(
                  children: [
                    const Text(
                      '适用于 Android 客户端，请您在应用商店下载 ntfy 软件，授予其适当的权限，点按右下角+添加订阅主题，名称自拟且必须具有较强的个性，否则您的成绩可能被配置同名的其他用户接收。自拟之后，勾选低功耗模式下实时推送复选框，然后点击右上角的“订阅”保存，随后将自拟的名称填写到本程序上面的 Topic 文本框。默认配置下无需配置服务器。请注意，国产 Android 手机厂商可能会杀掉 ntfy 的后台，为保证其适用性，请参阅 ',
                    ),
                    _link('dontkillmyapp.com', 'https://dontkillmyapp.com/'),
                    const Text(' 配置您的手机管家等软件。'),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.center,
                child: Wrap(
                  children: [
                    Text(
                      '如您发现转发失败，请',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: .48),
                      ),
                    ),
                    _link(
                      '与开发者联系',
                      'https://github.com/MaoRM93/GradeMonitor-for-RUC/issues',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
