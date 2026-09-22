// Engine | Flutter 3.x / Dart 3 | lib/ui/login_page.dart
// 登录页：记住密码（secure storage）、验证码弹窗、自动登录

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/cas_client.dart';
import '../core/session.dart';

class LoginPage extends StatefulWidget {
  final String? initialError;
  const LoginPage({super.key, this.initialError});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _remember = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _error = widget.initialError;
  }

  void _settle(String msg) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = msg;
    });
  }

  void _goHome() {
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/home');
  }

  Future<void> _submit({String? captcha}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Session.I.login(_user.text.trim(), _pass.text,
          captcha: captcha, remember: _remember);
      _goHome();
    } on CaptchaRequired catch (e) {
      _settle(e.message);
      final c = await _askCaptcha();
      if (c != null && c.isNotEmpty && mounted) await _submit(captcha: c);
    } on AuthFailed catch (e) {
      _settle(e.message);
    } catch (e) {
      _settle('网络异常：$e');
    }
  }

  Future<String?> _askCaptcha() {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _CaptchaDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Image.asset('assets/images/school_badge.png',
                    width: 96, height: 96),
              ),
              const SizedBox(height: 12),
              const Text('i泥航',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center),
              const SizedBox(height: 32),
              TextField(
                controller: _user,
                decoration: const InputDecoration(
                    labelText: '学号', prefixIcon: Icon(Icons.person)),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _pass,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: '密码', prefixIcon: Icon(Icons.lock)),
                onSubmitted: (_) => _submit(),
              ),
              CheckboxListTile(
                value: _remember,
                onChanged: (v) => setState(() => _remember = v ?? true),
                title: const Text('记住密码'),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child:
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                ),
              FilledButton(
                onPressed: _busy ? null : () => _submit(),
                child: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('登录'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }
}

class _CaptchaDialog extends StatefulWidget {
  const _CaptchaDialog();

  @override
  State<_CaptchaDialog> createState() => _CaptchaDialogState();
}

class _CaptchaDialogState extends State<_CaptchaDialog> {
  Uint8List? _bytes;
  bool _loading = true;
  final _code = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final b = await Session.I.fetchCaptcha();
      if (mounted) setState(() => _bytes = b);
    } catch (_) {
      if (mounted) setState(() => _bytes = null);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('请输入验证码'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: _reload,
            child: Container(
              width: 160,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.black26),
                borderRadius: BorderRadius.circular(6),
              ),
              child: _loading
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : _bytes == null
                      ? const Text('点此重试',
                          style: TextStyle(fontSize: 12, color: Colors.black45))
                      : Image.memory(_bytes!,
                          fit: BoxFit.contain, gaplessPlayback: false),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _code,
            autofocus: true,
            decoration: const InputDecoration(
                labelText: '验证码', hintText: '不区分大小写，点击图片可刷新'),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(context, _code.text.trim()),
            child: const Text('确定')),
      ],
    );
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }
}
