import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_theme.dart';
import '../../core/network/api_client.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/toast_host.dart';

const _termsText = '''免责声明

1. 本程序为个人开发项目，与任何学校、教育机构或教务系统运营方无关，非官方软件。

2. 本程序仅用于辅助用户查询个人成绩信息，使用过程中产生的账号异常、数据泄露、校规违反等风险，由用户自行承担。

3. 开发者不保证程序持续可用、无故障运行，不对因软件使用、系统环境变化或第三方服务异常造成的损失承担责任。

4. 开发者承诺不收集、不上传、不存储用户账号密码及成绩数据，相关信息仅在用户设备本地处理。

5. 用户应妥善保管账号信息、积极参与教评，并确保使用行为符合学校管理规定及相关法律法规。

用户使用协议

1. 用户下载、安装或使用本程序，即视为同意本协议全部内容。

2. 本程序仅限个人学习、研究及技术交流使用，禁止用于商业用途或未经授权的传播。

3. 用户不得利用本程序进行任何形式的服务器攻击、漏洞利用、数据爬取、恶意访问或其他影响学校计算机系统正常运行的行为。

4. 严禁通过降低查询间隔、批量账号运行、高频请求等方式增加教务系统服务器负担。

5. 用户因违规使用本程序造成的一切后果，由用户自行承担；开发者有权停止提供相关支持。

6. 如不同意上述条款，请立即停止使用并彻底删除本程序。''';

/// 欢迎页弹窗（4 步向导）
class WelcomeDialog extends ConsumerStatefulWidget {
  const WelcomeDialog({super.key});

  @override
  ConsumerState<WelcomeDialog> createState() => _WelcomeDialogState();
}

class _WelcomeDialogState extends ConsumerState<WelcomeDialog> {
  int _step = 0;
  static const _totalSteps = 4;
  static const _labels = ['使用协议', '账号登录', '监测设置', '完成设置'];

  // ---- Step 1: 协议 ----
  bool _agreed = false;
  int _countdown = 10;
  Timer? _countdownTimer;

  // ---- Step 2: 账号 ----
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _hidePassword = true;
  bool _rememberMe = false;
  bool _verifying = false;

  // ---- Step 3: 监控设置 ----
  bool _autoMonitor = false;
  bool _rankMonitor = false;
  double _intervalValue = 300;
  TimeOfDay _startTime = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay _endTime = const TimeOfDay(hour: 23, minute: 0);
  String _notifyMode = '详细';

  // ---- Step 4: 确认 ----
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _startCountdown();
    // 账号/密码输入实时刷新"下一步"可用状态
    _usernameCtrl.addListener(_refreshAccountState);
    _passwordCtrl.addListener(_refreshAccountState);
  }

  void _refreshAccountState() {
    if (mounted) setState(() {});
  }

  void _startCountdown() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() {
        _countdown--;
        if (_countdown <= 0) {
          t.cancel();
        }
      });
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  String _formatTime(TimeOfDay t) {
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _pickStartTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _startTime,
    );
    if (picked != null) setState(() => _startTime = picked);
  }

  Future<void> _pickEndTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _endTime,
    );
    if (picked != null) setState(() => _endTime = picked);
  }

  bool _canProceed() {
    switch (_step) {
      case 0:
        return _agreed;
      case 1:
        return _usernameCtrl.text.trim().isNotEmpty &&
            _passwordCtrl.text.isNotEmpty;
      case 2:
        return true;
      case 3:
        return true;
      default:
        return false;
    }
  }

  /// 点击「下一步」：账号登录步（step 1）立即做真实登录验证，
  /// 凭据无效则弹提示并留在本步，不允许进入后续步骤
  Future<void> _nextStep() async {
    if (_step == 1) {
      setState(() => _verifying = true);
      final result = await ref
          .read(settingsProvider.notifier)
          .login(_usernameCtrl.text.trim(), _passwordCtrl.text);
      if (!mounted) return;
      setState(() => _verifying = false);
      if (!result.success) {
        ToastHost().show(result.message);
        return;
      }
    }
    setState(() => _step++);
  }

  Future<void> _finish() async {
    setState(() => _saving = true);

    // 凭据已在账号登录步验证通过，这里只负责保存
    final notifier = ref.read(settingsProvider.notifier);
    final current = ref.read(settingsProvider);
    final updated = current.copyWith(
      username: _usernameCtrl.text.trim(),
      password: _passwordCtrl.text,
      rememberMe: _rememberMe,
      autoMonitorEnabled: _autoMonitor,
      rankMonitorEnabled: _rankMonitor,
      intervalSeconds: _intervalValue.toInt(),
      startTime: _formatTime(_startTime),
      endTime: _formatTime(_endTime),
      notifyMode: _notifyMode,
    );
    await notifier.saveSettings(updated);
    await ApiClient().completeWelcome();

    if (mounted) {
      ToastHost().show('设置已保存');
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 底色跟随系统主题：亮色纯白，深色用深底，避免深色模式下刺眼
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Theme(
      data: isDark ? AppTheme.darkTheme : AppTheme.lightTheme,
      child: Builder(
        builder: (context) {
          final colorScheme = Theme.of(context).colorScheme;
          return Dialog(
            backgroundColor: isDark ? const Color(0xFF1C1C1E) : Colors.white,
            insetPadding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 标题
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
                    child: Row(
                      children: [
                        Icon(
                          Icons.waving_hand_rounded,
                          color: colorScheme.primary,
                          size: 24,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '欢迎使用 GradeMonitor',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 步骤指示器 — 四步等距
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: SizedBox(
                      height: 52,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: List.generate(_totalSteps, (i) {
                          final completed = i < _step;
                          final active = i == _step;
                          return Expanded(
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    // 左侧连接线（第一步透明）
                                    Expanded(
                                      child: Container(
                                        height: 2,
                                        color: i > 0 && (completed || active)
                                            ? colorScheme.primary
                                            : Colors.transparent,
                                      ),
                                    ),
                                    // 圆圈
                                    Container(
                                      width: 28,
                                      height: 28,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: active
                                            ? colorScheme.primary
                                            : completed
                                            ? colorScheme.primary.withValues(
                                                alpha: .7,
                                              )
                                            : colorScheme
                                                  .surfaceContainerHighest,
                                        border: Border.all(
                                          color: active || completed
                                              ? colorScheme.primary
                                              : colorScheme.outlineVariant,
                                          width: 2,
                                        ),
                                      ),
                                      alignment: Alignment.center,
                                      child: completed
                                          ? const Icon(
                                              Icons.check,
                                              size: 16,
                                              color: Colors.white,
                                            )
                                          : Text(
                                              '${i + 1}',
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                color: active
                                                    ? colorScheme.onPrimary
                                                    : colorScheme.onSurface
                                                          .withValues(
                                                            alpha: .5,
                                                          ),
                                              ),
                                            ),
                                    ),
                                    // 右侧连接线（最后一步透明）
                                    Expanded(
                                      child: Container(
                                        height: 2,
                                        color: i < _totalSteps - 1 && completed
                                            ? colorScheme.primary
                                            : Colors.transparent,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  _labels[i],
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: active
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: active
                                        ? colorScheme.primary
                                        : colorScheme.onSurface.withValues(
                                            alpha: .5,
                                          ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
                      ),
                    ),
                  ),
                  const Divider(height: 1),

                  // 步骤内容
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                      child: _buildStepContent(colorScheme),
                    ),
                  ),

                  const Divider(height: 1),

                  // 底部按钮
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
                    child: Row(
                      children: [
                        // 不同意按钮（仅第一步显示）
                        if (_step == 0)
                          OutlinedButton(
                            onPressed: () => exit(0),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppTheme.error,
                              side: const BorderSide(color: AppTheme.error),
                            ),
                            child: const Text('不同意'),
                          ),
                        if (_step > 0) ...[
                          OutlinedButton(
                            onPressed: () => setState(() => _step--),
                            child: const Text('上一步'),
                          ),
                        ],
                        const Spacer(),
                        if (_step < _totalSteps - 1)
                          FilledButton(
                            onPressed: (_canProceed() && !_verifying)
                                ? _nextStep
                                : null,
                            child: _verifying
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text('下一步'),
                          )
                        else
                          FilledButton.icon(
                            onPressed: (_canProceed() && !_saving)
                                ? _finish
                                : null,
                            icon: _saving
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.check_rounded, size: 18),
                            label: Text(_saving ? '保存中...' : '同意并开始使用'),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildStepContent(ColorScheme colorScheme) {
    switch (_step) {
      case 0:
        return _buildAgreementStep(colorScheme);
      case 1:
        return _buildAccountStep(colorScheme);
      case 2:
        return _buildMonitorStep(colorScheme);
      case 3:
        return _buildConfirmStep(colorScheme);
      default:
        return const SizedBox.shrink();
    }
  }

  // ---- Step 1: 协议 ----

  /// 协议正文按空行自动分段，每段独立排版，段间距 5 像素
  Widget _buildTermsParagraphs(ColorScheme colorScheme) {
    final paragraphs = _termsText
        .split('\n\n')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < paragraphs.length; i++) ...[
          if (i > 0) const SizedBox(height: 5),
          Text(
            paragraphs[i],
            style: TextStyle(
              fontSize: 13,
              color: colorScheme.onSurface.withValues(alpha: .7),
              height: 1.45,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildAgreementStep(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '请仔细阅读以下协议',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          height: 240,
          decoration: BoxDecoration(
            border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: .5),
            ),
            borderRadius: BorderRadius.circular(8),
            color: colorScheme.surfaceContainerHighest.withValues(alpha: .3),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  children: [
                    Icon(
                      Icons.description_rounded,
                      size: 16,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '使用协议',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const Spacer(),
                    if (_countdown > 0)
                      Text(
                        '${_countdown}s 后可同意',
                        style: TextStyle(
                          fontSize: 11,
                          color: colorScheme.onSurface.withValues(alpha: .4),
                        ),
                      )
                    else
                      Text(
                        '请勾选下方复选框',
                        style: TextStyle(
                          fontSize: 11,
                          color: colorScheme.primary,
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: Scrollbar(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: _buildTermsParagraphs(colorScheme),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            SizedBox(
              height: 32,
              child: Checkbox(
                value: _agreed,
                onChanged: _countdown <= 0
                    ? (v) => setState(() => _agreed = v ?? false)
                    : null,
              ),
            ),
            GestureDetector(
              onTap: _countdown <= 0
                  ? () => setState(() => _agreed = !_agreed)
                  : null,
              child: Text(
                _countdown > 0
                    ? '请等待 ${_countdown}s 后勾选同意'
                    : (_agreed ? '我已阅读并同意上述协议' : '请勾选以同意上述协议'),
                style: TextStyle(
                  fontSize: 13,
                  color: _countdown > 0
                      ? colorScheme.onSurface.withValues(alpha: .35)
                      : colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ---- Step 2: 账号 ----
  Widget _buildAccountStep(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '配置教务系统账号',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '凭据仅保存在本地，不会上传到任何服务器。之后可在设置中修改。',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _usernameCtrl,
          decoration: const InputDecoration(
            labelText: '学号',
            hintText: '输入教务系统学号',
            isDense: true,
            prefixIcon: Icon(Icons.badge_rounded, size: 18),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _passwordCtrl,
          obscureText: _hidePassword,
          keyboardType: TextInputType.visiblePassword,
          enableSuggestions: false,
          autocorrect: false,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[\x00-\x7F]')),
          ],
          decoration: InputDecoration(
            labelText: '密码',
            hintText: '输入教务系统密码',
            isDense: true,
            prefixIcon: const Icon(Icons.key_rounded, size: 18),
            suffixIcon: IconButton(
              icon: Icon(
                _hidePassword
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
                size: 18,
              ),
              onPressed: () => setState(() => _hidePassword = !_hidePassword),
            ),
          ),
        ),
        const SizedBox(height: 14),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('记住密码', style: TextStyle(fontSize: 13)),
          value: _rememberMe,
          onChanged: (v) => setState(() => _rememberMe = v),
          dense: true,
        ),
      ],
    );
  }

  // ---- Step 3: 监控设置 ----
  Widget _buildMonitorStep(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '配置自动监控',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        Text('之后可在设置中修改。', style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: .3),
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                title: const Text('成绩自动监控', style: TextStyle(fontSize: 13)),
                subtitle: const Text(
                  '检测新出成绩或成绩变动',
                  style: TextStyle(fontSize: 11),
                ),
                value: _autoMonitor,
                onChanged: (v) => setState(() => _autoMonitor = v),
                dense: true,
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                title: const Text('排名自动监控', style: TextStyle(fontSize: 13)),
                subtitle: const Text(
                  '检测专业排名或班级排名变动',
                  style: TextStyle(fontSize: 11),
                ),
                value: _rankMonitor,
                onChanged: (v) => setState(() => _rankMonitor = v),
                dense: true,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(
          '监控时间段',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('开始', style: TextStyle(fontSize: 12)),
                trailing: Text(
                  _startTime.format(context),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onTap: _pickStartTime,
                dense: true,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('结束', style: TextStyle(fontSize: 12)),
                trailing: Text(
                  _endTime.format(context),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onTap: _pickEndTime,
                dense: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '通知模式',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: '详细', label: Text('完整模式')),
            ButtonSegment(value: '简洁', label: Text('简洁模式')),
          ],
          selected: {_notifyMode},
          onSelectionChanged: (v) => setState(() => _notifyMode = v.first),
          style: SegmentedButton.styleFrom(
            textStyle: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }

  // ---- Step 4: 确认 ----
  Widget _buildConfirmStep(ColorScheme colorScheme) {
    final monitorDesc = [];
    if (_autoMonitor) monitorDesc.add('成绩监控');
    if (_rankMonitor) monitorDesc.add('排名监控');
    final monitorText = monitorDesc.isEmpty ? '未开启' : monitorDesc.join(' + ');
    final timeText =
        '${_startTime.format(context)} - ${_endTime.format(context)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '确认配置',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '请确认以下设置，点击下方按钮完成配置。',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 16),
        _confirmRow(colorScheme, '学号', _usernameCtrl.text.trim()),
        _confirmRow(colorScheme, '密码', '•' * _passwordCtrl.text.length),
        const SizedBox(height: 8),
        _confirmRow(colorScheme, '自动监控', monitorText),
        _confirmRow(colorScheme, '监控时间', timeText),
        _confirmRow(colorScheme, '通知模式', _notifyMode == '详细' ? '完整模式' : '简洁模式'),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: colorScheme.primary.withValues(alpha: .08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: colorScheme.primary.withValues(alpha: .2),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline, size: 18, color: colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '完成配置后，程序将自动开始在后台监测成绩与排名变动。'
                  '所有数据仅保存在本地，请放心使用。',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurface.withValues(alpha: .7),
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _confirmRow(ColorScheme colorScheme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurface.withValues(alpha: .5),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '未设置' : value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
