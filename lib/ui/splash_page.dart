// Engine | Flutter 3.x / Dart 3 | lib/ui/splash_page.dart
// 开屏页：有已保存凭据时静默自动登录（仅图标 + 应用名 + 加载圈）；
// 首次启动 / 退出登录后 / 自动登录失败 → 账号密码登录页。

import 'package:flutter/material.dart';

import '../core/session.dart';
import 'login_page.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final u = await Session.I.storedUser();
    final p = await Session.I.storedPass();
    if (!mounted) return;
    if (u == null || p == null) {
      _toLogin();
      return;
    }
    try {
      await Session.I.login(u, p, silent: true);
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/home');
    } catch (_) {
      // 验证码/密码失效/网络问题 → 一律回登录页手动处理
      _toLogin();
    }
  }

  void _toLogin() {
    if (!mounted) return;
    Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => const LoginPage()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: Image.asset('assets/images/school_badge.png',
                  width: 120, height: 120),
            ),
            const SizedBox(height: 20),
            const Text('i泥航',
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold)),
            const SizedBox(height: 40),
            const CircularProgressIndicator(strokeWidth: 2),
          ],
        ),
      ),
    );
  }
}
