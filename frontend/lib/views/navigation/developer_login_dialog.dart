import 'package:flutter/material.dart';

import '../../core/network/api_client.dart';
import '../../core/service/nav_signal.dart';
import '../../core/service/ui_prefs_service.dart';
import '../../core/theme/app_theme.dart';

/// 开发者登录弹窗：用 GitHub 身份确认"操作者是作者本人"。
///
/// 标题固定为 `Login`，正文只有两个输入框：
///   - `Account`  = GitHub 账号名（后端用它反查管理者记录）
///   - `Password` = GitHub 令牌（GitHub 没有"账号 + 密码换令牌"的 API）
///
/// 语义见 `backend/service/developer_auth.py`。
///
/// 失败处理分两种，刻意不同：
///   - **身份不对**（401）：整张卡片切到拒绝态——红字提示 + 一个红色「好」
///     按钮关闭弹窗，不再给重试机会。这是"别人的账号"该看到的东西。
///   - **网络/服务异常**（其它）：保留表单，错误用小字提示在下方，可重试。
///
/// 注意：ApiClient 的 `validateStatus` 放行全部 4xx（业务接口靠状态码分支
/// 而不是靠抛异常），所以这里必须自己判断 `statusCode`，不能"请求没抛异常
/// 就当成功"——否则空输入会被后端拒绝、前端却当成登录成功。
class DeveloperLoginDialog extends StatefulWidget {
  final ApiClient api;
  const DeveloperLoginDialog({required this.api, super.key});

  @override
  State<DeveloperLoginDialog> createState() => _DeveloperLoginDialogState();
}

class _DeveloperLoginDialogState extends State<DeveloperLoginDialog> {
  final _account = TextEditingController();
  final _token = TextEditingController();

  bool _busy = false;
  bool _probing = true;
  String? _error;

  /// 已通过校验的登录名；非空表示本机已有有效开发者身份。
  String _existingLogin = '';

  /// 是否处于"账号非法"的拒绝态（切到红字 + 红色「好」按钮）。
  bool _rejected = false;

  /// 拒绝文案（与后端 `developer_auth.REJECT_MESSAGE` 保持一致）。
  static const String _rejectMessage = '您登录的不是合法的开发者账户。';

  @override
  void initState() {
    super.initState();
    // 不在打开弹窗时探测后端已登录状态。探测会读取开发者钥匙串凭据，
    // 而连续点击版本号只是打开入口，不应要求 macOS 授权。
    _probing = false;
  }

  @override
  void dispose() {
    _account.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final account = _account.text.trim();
    final token = _token.text.trim();
    // 空输入直接拦在前端，不发请求：后端会回 401，但没必要跑一趟网络。
    if (account.isEmpty || token.isEmpty) {
      setState(() => _error = '请输入 Account 与 Password。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.api.loginDeveloper(
        mngId: account,
        account: account,
        token: token,
      );
      if (!mounted) return;
      final code = r.statusCode ?? 0;
      final data = r.data;
      final ok =
          code >= 200 && code < 300 && data is Map && data['success'] == true;
      if (!ok) {
        if (code == 401) {
          setState(() => _rejected = true);
        } else {
          setState(() => _error = _detailOfResponse(data, code));
        }
        return;
      }
      await UiPrefsService.ensureLoaded();
      await UiPrefsService.writeBoolPref(
        UiPrefsService.prefDevPanelPinned,
        true,
      );
      if (!mounted) return;
      developerOptionsEnabled.value = true;
      requestNav(AppNavTarget.settings);
      Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 取后端 `detail` 字段；没有就按状态码给一句人话。
  String _detailOfResponse(Object? data, int code) {
    if (data is Map && data['detail'] != null) {
      return data['detail'].toString();
    }
    if (code == 0) return '登录失败，请稍后重试。';
    return '登录失败（HTTP $code）。';
  }

  Future<void> _logout() async {
    setState(() => _busy = true);
    try {
      await widget.api.logoutDeveloper();
      await UiPrefsService.ensureLoaded();
      await UiPrefsService.writeBoolPref(
        UiPrefsService.prefDevPanelPinned,
        false,
      );
      if (!mounted) return;
      developerOptionsEnabled.value = false;
      setState(() => _existingLogin = '');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Login'),
      content: SizedBox(
        width: 340,
        child: _probing
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            : _rejected
            ? _buildRejected(context)
            : _existingLogin.isNotEmpty
            ? _buildLoggedIn(context)
            : _buildForm(context),
      ),
      actions: _buildActions(context),
    );
  }

  /// 拒绝态：红字提示。只有一个红色「好」按钮（在 actions 里）。
  Widget _buildRejected(BuildContext context) => Text(
    _rejectMessage,
    style: TextStyle(
      color: AppTheme.error,
      fontSize: 14,
      fontWeight: FontWeight.w600,
      height: 1.5,
    ),
  );

  /// 已登录态：显示当前账号，提供退出登录。
  Widget _buildLoggedIn(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '已登录：$_existingLogin',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: _busy ? null : _logout,
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTheme.error,
            side: BorderSide(color: AppTheme.error.withValues(alpha: .5)),
          ),
          child: const Text('退出登录'),
        ),
      ],
    );
  }

  /// 表单态：Account + Password 两个输入框。
  Widget _buildForm(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _account,
          autofocus: true,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: 'Account'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _token,
          obscureText: true,
          style: const TextStyle(letterSpacing: -2.4),
          onSubmitted: (_) => _busy ? null : _submit(),
          decoration: const InputDecoration(labelText: 'Password'),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              _error!,
              style: TextStyle(color: cs.error, fontSize: 12, height: 1.4),
            ),
          ),
      ],
    );
  }

  List<Widget> _buildActions(BuildContext context) {
    if (_rejected) {
      // 唯一的红色「好」：关闭弹窗，不重试
      return [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          style: FilledButton.styleFrom(
            backgroundColor: AppTheme.error,
            foregroundColor: Colors.white,
          ),
          child: const Text('好'),
        ),
      ];
    }
    if (_probing) return const [];
    if (_existingLogin.isNotEmpty) {
      return [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('好'),
        ),
      ];
    }
    return [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy ? null : _submit,
        child: Text(_busy ? '验证中…' : '登录'),
      ),
    ];
  }
}
