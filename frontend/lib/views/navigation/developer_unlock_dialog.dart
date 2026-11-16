import 'package:flutter/material.dart';
import '../../core/network/api_client.dart';
import '../../core/service/nav_signal.dart';

class DeveloperUnlockDialog extends StatefulWidget {
  final ApiClient api;
  const DeveloperUnlockDialog({required this.api});
  @override State<DeveloperUnlockDialog> createState() => _DeveloperUnlockDialogState();
}
class _DeveloperUnlockDialogState extends State<DeveloperUnlockDialog> {
  final _password = TextEditingController(); bool _busy = false; String? _error;
  @override void dispose() { _password.dispose(); super.dispose(); }
  Future<void> _unlock() async {
    setState(() { _busy = true; _error = null; });
    try { await widget.api.unlockDeveloper(_password.text); if (!mounted) return; developerOptionsEnabled.value = true; requestNav(AppNavTarget.settings); Navigator.pop(context); }
    catch (e) { if (mounted) setState(() => _error = '无法解锁：$e'); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('开发者选项'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('输入开发者密码后，设置页会显示开发者选项。'),
            const SizedBox(height: 14),
            TextField(
              controller: _password, obscureText: true, autofocus: true,
              onSubmitted: (_) => _unlock(),
              decoration: const InputDecoration(labelText: '开发者密码', border: OutlineInputBorder()),
            ),
            if (_error != null) Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _busy ? null : _unlock, child: Text(_busy ? '验证中…' : '开启')),
      ],
    );
  }
}
