import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/network/api_client.dart';
import '../../core/theme/app_theme.dart';
import '../../core/service/feature_gate_service.dart';
import '../../widgets/feature_gate.dart';
import '../../widgets/expressive_switch.dart';
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
  String? _togglingChannel;
  bool _bark = false, _meow = false, _ntfy = false, _loading = true;
  bool _barkConfigured = false,
      _meowConfigured = false,
      _ntfyConfigured = false;
  bool _showBarkKey = false;
  bool _showMeowKey = false;
  bool _showNtfyServer = false;
  bool _showNtfyTopic = false;

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
        // 会话内草稿优先，其次是后端已落盘的凭据。开关是唯一能改 enabled 的
        // 入口，所以开关状态一律取后端值，不在本地猜。
        _barkUrl.text =
            _savedDrafts['bark']?['url'] ?? bark['url']?.toString() ?? '';
        _meowNickname.text =
            _savedDrafts['meow']?['nickname'] ??
            meow['nickname']?.toString() ??
            '';
        _ntfyServer.text =
            _savedDrafts['ntfy']?['server'] ??
            ntfy['server']?.toString() ??
            'https://ntfy.sh';
        _ntfyTopic.text =
            _savedDrafts['ntfy']?['topic'] ?? ntfy['topic']?.toString() ?? '';
        _bark = bark['enabled'] == true;
        _meow = meow['enabled'] == true;
        _ntfy = ntfy['enabled'] == true;
        _barkConfigured = _barkUrl.text.trim().isNotEmpty;
        _meowConfigured = _meowNickname.text.trim().isNotEmpty;
        _ntfyConfigured = _ntfyTopic.text.trim().isNotEmpty;
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

  /// 各通道可编辑的凭据字段。保存与开关都复用这一份，避免两套取值逻辑。
  ///
  /// 空值一律不提交：后端把空的 url/nickname/topic 视为「保留已保存配置」，
  /// 少传与传空串等价；而 server 传空串会把默认服务器写成空，这里直接省略。
  Map<String, String> _credentials(String channel) {
    final raw = switch (channel) {
      'bark' => {'url': _barkUrl.text.trim()},
      'meow' => {'nickname': _meowNickname.text.trim()},
      _ => {
        'server': _ntfyServer.text.trim(),
        'topic': _ntfyTopic.text.trim(),
      },
    };
    return {
      for (final e in raw.entries)
        if (e.value.isNotEmpty) e.key: e.value,
    };
  }

  /// 输入框里有值，或后端已存过该通道的凭据，都算可开启。
  ///
  /// 只看输入框会把「已保存过但本次会话回填失败」的通道误判为未配置。
  bool _canEnable(String channel) => switch (channel) {
    'bark' => _barkConfigured || _barkUrl.text.trim().isNotEmpty,
    'meow' => _meowConfigured || _meowNickname.text.trim().isNotEmpty,
    _ => _ntfyConfigured || _ntfyTopic.text.trim().isNotEmpty,
  };

  /// 用后端返回的完整快照刷新本通道状态。
  ///
  /// 开关值也以响应为准：开关是唯一能改 `enabled` 的入口，本地乐观值必须在
  /// 落盘成功后与后端对齐，避免界面显示已开启而后端其实没开。
  void _applyResponse(String channel, Map data) {
    final forwarders = data['forwarders'] as Map?;
    final entry = forwarders?[channel] as Map?;
    final configured = entry?['configured'] == true;
    final enabled = entry?['enabled'] == true;
    if (channel == 'bark') {
      _barkConfigured = configured;
      _bark = enabled;
    }
    if (channel == 'meow') {
      _meowConfigured = configured;
      _meow = enabled;
    }
    if (channel == 'ntfy') {
      _ntfyConfigured = configured;
      _ntfy = enabled;
    }
  }

  /// 仅保存凭据，不改变转发开关状态。
  ///
  /// 请求体里刻意不带 `enabled`：后端只在字段出现时才覆盖，缺失即保留已落盘
  /// 的开关值。这样「保存」永远不会把用户已经打开的转发静默关掉，也不会在
  /// 用户没点开关时提前开启转发。
  Future<void> _saveChannel(String channel) async {
    setState(() {
      _savingChannel = channel;
      _saveLabels.remove(channel);
    });
    final credentials = _credentials(channel);
    try {
      final response = await _api.updateNotificationForwarders({
        channel: credentials,
      });
      if (!mounted) return;
      setState(() {
        _applyResponse(channel, response.data as Map);
        _savedDrafts[channel] = Map<String, String>.from(credentials);
        _dirty.remove(channel);
        _saveLabels[channel] = '已保存';
      });
    } catch (_) {
      if (mounted) setState(() => _saveLabels[channel] = '保存失败');
    } finally {
      if (mounted) setState(() => _savingChannel = null);
    }
  }

  /// 右上角开关：点击即落盘生效，不需要再点保存。
  ///
  /// 顺带把当前输入框里的凭据一起提交，避免「填了地址直接打开开关」时后端拿
  /// 到的是上一次保存的旧值。失败时回滚开关显示，不伪造生效状态。
  Future<void> _toggleChannel(String channel, bool next) async {
    if (_togglingChannel != null || _savingChannel != null) return;
    if (next && !_canEnable(channel)) {
      ToastHost().show('请先填写该通道的配置，再开启转发');
      return;
    }
    final previous = switch (channel) {
      'bark' => _bark,
      'meow' => _meow,
      _ => _ntfy,
    };
    setState(() {
      _togglingChannel = channel;
      if (channel == 'bark') _bark = next;
      if (channel == 'meow') _meow = next;
      if (channel == 'ntfy') _ntfy = next;
    });
    final credentials = _credentials(channel);
    try {
      final response = await _api.updateNotificationForwarders({
        channel: {'enabled': next, ...credentials},
      });
      if (!mounted) return;
      setState(() {
        _applyResponse(channel, response.data as Map);
        _savedDrafts[channel] = Map<String, String>.from(credentials);
        _dirty.remove(channel);
        _saveLabels[channel] = '已保存';
      });
      ToastHost().show(next ? '已开启转发' : '已关闭转发');
    } catch (_) {
      if (!mounted) return;
      setState(() {
        if (channel == 'bark') _bark = previous;
        if (channel == 'meow') _meow = previous;
        if (channel == 'ntfy') _ntfy = previous;
      });
      ToastHost().show('开关切换失败，请检查本机后端是否在运行');
    } finally {
      if (mounted) setState(() => _togglingChannel = null);
    }
  }

  Future<void> _test(String channel) async {
    try {
      final data = (await _api.testNotificationForwarder(channel)).data as Map;
      if (mounted) {
        ToastHost().show('${channel.toUpperCase()} 测试：${data['message']}');
      }
    } catch (e) {
      if (mounted) ToastHost().show('测试失败：$e');
    }
  }

  Future<void> _openLink(String url) async {
    try {
      if (Platform.isMacOS) {
        await Process.start('open', [url]);
      } else if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', url]);
      } else {
        await Process.start('xdg-open', [url]);
      }
    } catch (_) {
      if (mounted) ToastHost().show('无法打开链接');
    }
  }

  InputDecoration _field(
    String label,
    String? hint, {
    required bool revealed,
    required VoidCallback onToggleReveal,
  }) => InputDecoration(
    labelText: label,
    hintText: hint,
    labelStyle: const TextStyle(letterSpacing: 0),
    floatingLabelStyle: const TextStyle(letterSpacing: 0),
    hintStyle: const TextStyle(letterSpacing: 0),
    suffixIcon: IconButton(
      tooltip: revealed ? '隐藏内容' : '显示内容',
      icon: Icon(
        revealed ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        size: 19,
      ),
      onPressed: onToggleReveal,
    ),
  );

  TextStyle? _secretStyle(bool revealed) =>
      revealed ? null : const TextStyle(letterSpacing: -1.2);

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
    required List<Widget> fields,
    required Widget description,
  }) {
    final cs = Theme.of(context).colorScheme;
    final canTest =
        configured && !_dirty.contains(id) && _savingChannel == null;
    final isSaving = _savingChannel == id;
    final busy = _savingChannel != null || _togglingChannel != null;
    final label = isSaving ? '保存中…' : (_saveLabels[id] ?? '保存此通道');
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        // 通道卡靠比页面高一阶的表面色与背景区分，不用阴影。
        color: AppShape.groupFill(cs),
        borderRadius: AppShape.outer,
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
                    fontFamily: AppTheme.serifFontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 17,
                  ),
                ),
              ),
              // 开关即生效：点击后立刻落盘，不需要再点「保存此通道」。
              // 请求进行中禁用点击，避免并发写入互相覆盖。
              ExpressiveSwitch(
                value: enabled,
                onChanged: busy ? null : (value) => _toggleChannel(id, value),
                height: 30,
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...fields,
          const SizedBox(height: 10),
          DefaultTextStyle(
            // DefaultTextStyle 会整体替换父级样式，这里显式带上应用字体，
            // 否则说明文字会退回系统默认字体，与页面其余文本不一致。
            style: TextStyle(
              fontFamily: AppTheme.sansFontFamily,
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
                onPressed: busy ? null : () => _saveChannel(id),
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
              // Flag-1033：通道测试按钮可被远程静默下线
              if (featureEnabled(FeatureGateService.flag1033ForwarderTest))
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
                style: TextStyle(
                  fontFamily: AppTheme.serifFontFamily,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 20),
              FeatureGate(
                flag: FeatureGateService.flag1030Bark,
                child: _channel(
                  title: 'Bark',
                  icon: SvgPicture.asset(
                    'assets/Apple_Logo_Blue.svg',
                    colorFilter: ColorFilter.mode(cs.primary, BlendMode.srcIn),
                  ),
                  enabled: _bark,
                  configured: _barkConfigured,
                  id: 'bark',
                  fields: [
                    TextField(
                      controller: _barkUrl,
                      obscureText: !_showBarkKey,
                      style: _secretStyle(_showBarkKey),
                      onChanged: (_) => _markDirty('bark'),
                      decoration: _field(
                        '地址和 Key',
                        'https://api.day.app/你的设备密钥',
                        revealed: _showBarkKey,
                        onToggleReveal: () =>
                            setState(() => _showBarkKey = !_showBarkKey),
                      ),
                    ),
                  ],
                  description: const Text(
                    '适用于 iPhone 和 iPad 端，请您在 App Store 中下载 Bark 软件，授予其适当权限，并点击服务器页面复制按钮右侧的向下箭头，复制地址和Key，将得到的内容粘贴到本程序上面的文本框。',
                  ),
                ),
              ),
              FeatureGate(
                flag: FeatureGateService.flag1031Meow,
                child: _channel(
                  title: 'Meow',
                  icon: SvgPicture.asset(
                    'assets/harmonyos_o.svg',
                    width: 20,
                    height: 26,
                    colorFilter: ColorFilter.mode(cs.primary, BlendMode.srcIn),
                  ),
                  enabled: _meow,
                  configured: _meowConfigured,
                  id: 'meow',
                  fields: [
                    TextField(
                      controller: _meowNickname,
                      obscureText: !_showMeowKey,
                      style: _secretStyle(_showMeowKey),
                      onChanged: (_) => _markDirty('meow'),
                      decoration: _field(
                        '昵称',
                        null,
                        revealed: _showMeowKey,
                        onToggleReveal: () =>
                            setState(() => _showMeowKey = !_showMeowKey),
                      ),
                    ),
                  ],
                  description: const Text(
                    '适用于 HarmonyOS 端，请您在 App Gallery / 应用市场 中下载 Meow 应用，'
                    '授予其适当的权限，点击我的-登录华为账号，然后自定义下方的 Meow 昵称。'
                    '将您自定义或默认的 Meow 昵称填入到本程序上面的文本框。'
                    '请注意，您如果修改过 Meow 昵称，请填写您修改后的字段。'
                    '本字段支持中文昵称。',
                  ),
                ),
              ),
              FeatureGate(
                flag: FeatureGateService.flag1032Ntfy,
                child: _channel(
                  title: 'ntfy',
                  icon: Icon(
                    Icons.android_rounded,
                    color: cs.primary,
                    size: 26,
                  ),
                  enabled: _ntfy,
                  configured: _ntfyConfigured,
                  id: 'ntfy',
                  fields: [
                    TextField(
                      controller: _ntfyServer,
                      obscureText: !_showNtfyServer,
                      style: _secretStyle(_showNtfyServer),
                      onChanged: (_) => _markDirty('ntfy'),
                      decoration: _field(
                        '服务器',
                        null,
                        revealed: _showNtfyServer,
                        onToggleReveal: () =>
                            setState(() => _showNtfyServer = !_showNtfyServer),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _ntfyTopic,
                      obscureText: !_showNtfyTopic,
                      style: _secretStyle(_showNtfyTopic),
                      onChanged: (_) => _markDirty('ntfy'),
                      decoration: _field(
                        'Topic',
                        '例如 grade_随机长字符串',
                        revealed: _showNtfyTopic,
                        onToggleReveal: () =>
                            setState(() => _showNtfyTopic = !_showNtfyTopic),
                      ),
                    ),
                  ],
                  description: Wrap(
                    children: [
                      const Text(
                        '适用于 Android 客户端，请您在应用商店下载 ntfy 软件，授予其适当的权限，点按右下角+添加订阅主题，名称自拟且必须具有较强的个性，否则您的成绩可能被配置同名的其他用户接收。自拟之后，勾选低功耗模式下实时推送复选框，然后点击右上角的“订阅”保存，随后将自拟的名称填写到本程序上面的 Topic 文本框。默认配置下无需配置服务器。请注意，国产 Android 手机厂商可能会杀掉 ntfy 的后台，为保证其适用性，请参阅 ',
                      ),
                      _link('dontkillmyapp.com', 'https://dontkillmyapp.com/'),
                      const Text(
                        ' 配置您的手机管家等软件。'
                        '由于 ntfy 客户端限制标题字段必须为您自定义的 Topic 值，'
                        '因此，您所收到的信息将与其它通道略有差异。具体以实际情况为准。',
                      ),
                    ],
                  ),
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
