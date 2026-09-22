// Engine | Flutter 3.x / Dart 3 | lib/core/cas_client.dart
// 南航统一身份认证（wisedu authserver）：密码 AES-128-CBC（页内盐），
// 明文 = 64位随机串 + 密码，随机IV前置后整体 base64。
//
// 关键点：dio 自动跟随重定向会丢掉中间跳转的 Set-Cookie —— EAMS 的
// JSESSIONID 恰好在 ticket 校验那跳 302 里下发。所以这里手动逐跳跟随，
// 保证每一跳都经过 CookieManager；URL 里的 ;jsessionid= 也兜底进 jar。

import 'dart:math';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:encrypt/encrypt.dart';

class CasClient {
  final Dio dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
    followRedirects: false, // 手动跟随，中间 3xx 的 Set-Cookie 不能丢
    validateStatus: (code) => code != null && code < 400,
    headers: {
      'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
    },
  ));
  final CookieJar jar = CookieJar();

  CasClient() {
    dio.interceptors.add(CookieManager(jar));
  }

  static const _eams = 'https://aao-eas.nuaa.edu.cn';

  /// 完整登录。EAMS 会话仍有效时直接返回；缺验证码抛 [CaptchaRequired]，
  /// 拿到验证码后带 [captcha] 重调（Session 层会复用同一 CAS 会话）。
  Future<void> login(String username, String password, {String? captcha}) async {
    // 1. 摸受保护页：最终落在 aao-eas 域 = 会话有效；落在 authserver = 需要登录
    //    （新版认证平台页面里没有 casLoginForm 字样，不能靠 HTML 判断）
    final gate = await _follow('$_eams/eams/homeExt.action');
    if (gate.realUri.host.contains('aao-eas')) {
      return; // EAMS 会话还活着
    }
    final gateHtml = gate.data as String;
    final casUrl = gate.realUri.toString();

    // 2. 解析登录页：盐（隐藏域 pwdEncryptSalt，无 name 属性）/ execution / lt
    final salt = _saltFrom(gateHtml) ??
        RegExp(r'pwdDefaultEncryptSalt\s*=\s*"([^"]+)"')
            .firstMatch(gateHtml)
            ?.group(1);
    final execution = _hidden(gateHtml, 'execution') ?? '';
    final lt = _hidden(gateHtml, 'lt');

    if (captcha == null && await needCaptcha(username)) {
      throw const CaptchaRequired();
    }

    // 3. 提交（与页面 login.js 提交的字段一致）
    final post = await dio.post(
      casUrl,
      data: {
        'username': username,
        'password': salt == null ? password : _encryptAes(password, salt),
        '_eventId': 'submit',
        'cllt': 'userNameLogin',
        'dllt': 'generalLogin',
        'execution': execution,
        'lt': ?lt,
        'captcha': ?captcha,
        'rememberMe': 'true',
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    final postHtml = post.data as String;
    if (postHtml.contains('您提供的用户名或者密码有误')) {
      throw const AuthFailed('用户名或密码有误');
    }
    if (postHtml.contains('验证码有误') || postHtml.contains('验证码不正确')) {
      throw const CaptchaRequired(message: '验证码错误');
    }

    // 4. 跟完 ticket 校验链，回 EAMS 验会话：最终落在 aao-eas 域才算成功
    final loc = post.headers.value('location');
    if (loc != null) {
      await _follow(_abs(casUrl, loc));
    }
    final check = await _follow('$_eams/eams/homeExt.action');
    if (check.realUri.host.contains('aao-eas')) {
      return;
    }
    if (await needCaptcha(username)) {
      throw const CaptchaRequired(message: '需要验证码');
    }
    throw const AuthFailed('登录未生效，请重试');
  }

  /// 连续失败后 CAS 强制验证码；此接口预判（接口异常时静默跳过）
  Future<bool> needCaptcha(String username) async {
    try {
      final res = await dio.get(
          'http://authserver.nuaa.edu.cn/authserver/needCaptcha.html',
          queryParameters: {'username': username});
      return (res.data as String).trim().toLowerCase() == 'true';
    } catch (_) {
      return false;
    }
  }

  /// 验证码图片字节（走同一 cookie 会话，验证码绑定当前 CAS session）
  Future<Uint8List> fetchCaptcha() async {
    final res = await dio.get<List<int>>(
      'http://authserver.nuaa.edu.cn/authserver/getCaptcha.html',
      queryParameters: {'ts': '${DateTime.now().millisecondsSinceEpoch}'},
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(res.data!);
  }

  /// 手动逐跳 GET：每一跳都经过 CookieManager，Set-Cookie 全部入 jar。
  /// 注意：不要在这里做任何“兜底写 cookie”——服务器下发的会话 cookie
  /// 与 URL 里的 jsessionid 在认证后可能不同步，人为写入会造成同名冲突。
  Future<Response> _follow(String url) async {
    var current = url;
    for (var i = 0; i < 10; i++) {
      final r = await dio.get(current);
      final status = r.statusCode ?? 0;
      final loc = r.headers.value('location');
      if (status >= 300 && status < 400 && loc != null) {
        current = _abs(current, loc);
        continue;
      }
      return r;
    }
    throw const AuthFailed('重定向次数过多');
  }

  String _abs(String base, String loc) {
    if (loc.startsWith('http://') || loc.startsWith('https://')) return loc;
    final b = Uri.parse(base);
    final root = '${b.scheme}://${b.host}'
        '${b.hasPort ? ':${b.port}' : ''}';
    return loc.startsWith('/') ? '$root$loc' : '$root/$loc';
  }

  String? _hidden(String html, String name) {
    final m1 = RegExp('name="$name"[^>]*value="([^"]*)"').firstMatch(html);
    final m2 = RegExp('value="([^"]*)"[^>]*name="$name"').firstMatch(html);
    return m1?.group(1) ?? m2?.group(1);
  }

  /// 盐在 <input type="hidden" id="pwdEncryptSalt" value="...">（无 name 属性）
  String? _saltFrom(String html) {
    final m1 =
        RegExp('id="pwdEncryptSalt"[^>]*value="([^"]*)"').firstMatch(html);
    final m2 =
        RegExp('value="([^"]*)"[^>]*id="pwdEncryptSalt"').firstMatch(html);
    return m1?.group(1) ?? m2?.group(1);
  }

  /// 与 authserver 页面 encrypt.js 完全一致：
  /// 明文 = 64位随机串 + 密码；AES-128-CBC/PKCS7，key=盐(16B)，IV 随机 16 字符
  /// 但【不随密文传输】—— 服务端解密后丢弃前 64 字符（IV 差异只影响第 1 块）。
  /// 输出 = base64(纯密文)，即 CryptoJS.AES.encrypt(...).toString()。
  String _encryptAes(String password, String salt) {
    const chars = 'ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678';
    final rnd = Random.secure();
    String rand(int n) =>
        List.generate(n, (_) => chars[rnd.nextInt(chars.length)]).join();

    final key = Key.fromUtf8(salt); // 16 字符 -> AES-128
    final iv = IV.fromUtf8(rand(16));
    final cipher =
        Encrypter(AES(key, mode: AESMode.cbc)).encrypt(rand(64) + password, iv: iv);
    return cipher.base64;
  }
}

class AuthFailed implements Exception {
  final String message;
  const AuthFailed(this.message);
  @override
  String toString() => message;
}

class CaptchaRequired implements Exception {
  final String message;
  const CaptchaRequired({this.message = '需要验证码'});
  @override
  String toString() => message;
}
