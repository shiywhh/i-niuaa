// Engine | Flutter 3.x / Dart 3 | lib/core/session.dart
// 会话单例：凭据安全存储、验证码流程保留 CAS 会话、EAMS 过期静默重登

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'card_client.dart';
import 'cas_client.dart';
import 'eams_client.dart';

class Session extends ChangeNotifier {
  Session._();
  static final Session I = Session._();

  static const _kUser = 'nuaa.username';
  static const _kPass = 'nuaa.password';

  late SharedPreferences prefs;
  final _secure = const FlutterSecureStorage();

  CasClient? _cas;
  CasClient? _pending; // 验证码流程中保留的 CAS 会话（验证码绑定 session）
  EamsClient? _eams;
  CardClient? _card;

  bool get loggedIn => _eams != null;

  EamsClient get eams {
    final e = _eams;
    if (e == null) throw StateError('未登录');
    return e;
  }

  /// 一卡通客户端：与 EAMS 共用同一 CAS 会话（同一 cookie jar，SSO 免密）。
  /// 会话过期由 CardClient 抛 SessionExpired，经 [guard] 重登后这里必须
  /// 换到新 jar —— 所以重登路径上都要置空 [_card]。
  CardClient get card {
    if (_eams == null) throw StateError('未登录');
    final cas = _cas;
    if (cas == null) throw StateError('未登录');
    return _card ??= CardClient(cas.dio);
  }

  Future<void> init() async {
    prefs = await SharedPreferences.getInstance();
  }

  Future<String?> storedUser() => Future.value(prefs.getString(_kUser));
  Future<String?> storedPass() => _secure.read(key: _kPass);

  Future<void> login(String username, String password,
      {String? captcha, bool remember = true, bool silent = false}) async {
    final cas = _pending ?? CasClient();
    try {
      await cas.login(username, password, captcha: captcha);
      _pending = null;
      _cas = cas;
      _eams = EamsClient(cas.dio);
      _card = null;
      if (remember && !silent) {
        await prefs.setString(_kUser, username);
        await _secure.write(key: _kPass, value: password);
      }
      notifyListeners();
    } on CaptchaRequired {
      _pending = cas;
      rethrow;
    } on AuthFailed {
      _pending = cas; // 保留会话供验证码重试
      rethrow;
    }
  }

  Future<Uint8List> fetchCaptcha() {
    final cas = _pending ?? (_pending = CasClient());
    return cas.fetchCaptcha();
  }

  /// EAMS 会话过期时用已存凭据重登一次再重试。
  /// 请求串行排队：并发页面的重登/请求交错会互相踢掉会话，必须排队。
  Future<void> _queue = Future.value();

  Future<T> guard<T>(Future<T> Function() action) {
    Future<T> task() async {
      try {
        return await action();
      } on SessionExpired {
        final u = prefs.getString(_kUser);
        final p = await _secure.read(key: _kPass);
        if (u == null || p == null) rethrow;
        final cas = CasClient();
        await cas.login(u, p);
        _cas = cas;
        _eams = EamsClient(cas.dio);
        _card = null;
        notifyListeners();
        return action();
      }
    }
    final f = _queue.then((_) => task());
    _queue = f.then<void>((_) {}, onError: (_) {});
    return f;
  }

  /// 用已存凭据重新走一遍 EAMS CAS 登录（恢复 TGT）
  Future<void> reloginEams() async {
    final u = prefs.getString(_kUser);
    final p = await _secure.read(key: _kPass);
    if (u == null || p == null) throw StateError('未保存登录凭据');
    final cas = CasClient();
    await cas.login(u, p);
    _cas = cas;
    _eams = EamsClient(cas.dio);
    _card = null;
    notifyListeners();
  }

  Future<void> logout() async {
    try {
      await _cas?.dio.get('https://aao-eas.nuaa.edu.cn/eams/logout.action');
    } catch (_) {}
    _cas = null;
    _eams = null;
    _pending = null;
    _card = null;
    await _secure.delete(key: _kPass);
    notifyListeners();
  }
}
