// Engine | Flutter 3.x / Dart 3 | lib/core/card_client.dart
// 一卡通平台（onecardshall.nuaa.edu.cn，新中新 berserker）付款码链路：
//   1. authserver CAS SSO —— 复用 EAMS 登录后的 cookie jar（同一 TGC），免密直通
//   2. 跟随 berserker 回调 302 链，从 Location 提取加密 ticket（一次百分号解码）
//   3. POST /berserker-auth/oauth/token（logintype=sso，Basic 客户端凭证）换 JWT
//   4. synjones-auth: bearer <JWT> 头调 /berserker-base/user 与 batchGetBarCodeGet
// JWT 有效期约 70 天，内存缓存；接口 401 时整链重走一次。
// 卡片充值（H5 /campus-card/cardRecharge 的原生复刻）：
//   5. GET /berserker-app/ykt/tsm/queryCard 取卡户与余额
//   6. 表单 POST /charge/order/thirdOrder（SHA256 排序签名，密钥在页面 JS 里）
//      服务端 302 回 /payment/index?orderid=..&token=..，拿到订单号后把收银台
//      URL 交给外部浏览器完成支付（支付宝/微信收银台无法也不应在 app 内复刻）。
// CAS 会话已死（SSO 直通失败）时抛 SessionExpired，由 Session.guard 统一重登。

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'eams_client.dart' show SessionExpired;
import 'models.dart';

/// 一卡通账户信息（/berserker-base/user）
class CardUser {
  final String name, sno, cardAccount;
  const CardUser(this.name, this.sno, this.cardAccount);
}

class CardAuthExpired implements Exception {
  final String message = '一卡通会话已过期';
  const CardAuthExpired();
}

class CardAuthFailed implements Exception {
  final String message;
  const CardAuthFailed(this.message);
  @override
  String toString() => message;
}

class CardClient {
  /// 与 EAMS 共用的 dio（手动跟重定向 + 共享 cookie jar）
  final Dio dio;
  CardClient(this.dio);

  static const _base = 'https://onecardshall.nuaa.edu.cn';

  /// 与 H5 一致的 CAS service：berserker 回调校验 ST 后 302 回 plat 并附带加密 ticket
  static const _service =
      '$_base/berserker-auth/cas/login/wisedu?targetUrl=$_baseEncoded';
  static const _baseEncoded =
      'https%3A%2F%2Fonecardshall.nuaa.edu.cn%2Fplat%2F%3Fname%3DloginTransit%26device_token%3Dh5';

  /// 登录页 login.js 里钉死的公开客户端凭证（与网页版完全一致）
  static const _basicAuth =
      'Basic bW9iaWxlX3NlcnZpY2VfcGxhdGZvcm06bW9iaWxlX3NlcnZpY2VfcGxhdGZvcm1fc2VjcmV0';

  String? _token;

  Map<String, String> _authHeader() => {'synjones-auth': 'bearer ${_token!}'};

  Options _opts({Map<String, String>? headers}) => Options(
        headers: headers,
        // 平台用 HTTP 200 + body.code 表达业务错误，401 也要能读到 body
        validateStatus: (c) => c != null && c < 500,
      );

  /// 一次取全：账户信息 + 当前有效付款码批次。401 自动重走一遍链路。
  Future<(PayCodeBatch, CardUser)> fetchAll() async {
    if (_token == null) await _loginCard();
    try {
      final user = await _user();
      final batch = await _codes(user.cardAccount);
      return (batch, user);
    } on CardAuthExpired {
      _token = null;
      await _loginCard();
      final user = await _user();
      final batch = await _codes(user.cardAccount);
      return (batch, user);
    }
  }

  // ── 卡片充值（chunk-7d526474 模块 89eb / cardRecharge confirm() 的复刻）──

  /// 充值网关公开客户端凭证：appid 与 secret 都钉在网页 JS 里（非用户凭据）
  static const _payAppId = '56321';
  static const _paySecret = '0osTIhce7uPvDKHz6aa67bhCukaKoYl4';

  /// NUAA 的充值费目（frontInfo 接口 frontConfig.recharge）
  static const _feeItemId = '401';

  /// 卡户信息 + 余额（元）。取第一张实体卡。
  Future<RechargeAccount> queryRechargeAccount() async {
    if (_token == null) await _loginCard();
    try {
      return await _queryCard();
    } on CardAuthExpired {
      _token = null;
      await _loginCard();
      return _queryCard();
    }
  }

  Future<RechargeAccount> _queryCard() async {
    final res = await dio.get('$_base/berserker-app/ykt/tsm/queryCard',
        queryParameters: {'scene': 'recharge', 'synAccessSource': 'h5'},
        options: _opts(headers: _authHeader()));
    final body = _body(res, '查询卡户');
    final data = body['data'];
    final cards = data is Map ? data['card'] as List? : null;
    if (cards == null || cards.isEmpty) {
      throw const CardAuthFailed('未查询到可充值的校园卡');
    }
    final card = cards.first as Map;
    // 余额以 accinfo（电子账户，充值实时到账）为准；db_balance 是卡 chip
    // 余额，要 POS 刷卡后才写入，拿它显示会一直 0.00
    final accinfo = (card['accinfo'] as List? ?? []).cast<Map>();
    final accBalance =
        accinfo.isEmpty ? null : num.tryParse('${accinfo.first['balance']}');
    final dbBalance = num.tryParse('${card['db_balance']}') ?? 0;
    final unsettle = num.tryParse('${card['unsettle_amount']}') ?? 0;
    return RechargeAccount(
      name: '${card['name'] ?? ''}',
      account: '${card['account'] ?? ''}',
      cardName: (card['cardname'] as String?)?.isNotEmpty == true
          ? '${card['cardname']}'
          : '${card['card_name'] ?? '校园卡'}',
      cardType: '${card['cardtype'] ?? ''}',
      balanceYuan:
          (accBalance ?? (dbBalance + unsettle) / 100) / 100,
      lostFlag: '${card['lostflag']}' == '1',
    );
  }

  /// 创建充值订单，返回支付收银台页地址（/payment/index?orderid=..&token=..）。
  /// 交给外部浏览器打开完成支付；[amountYuan] 为元。
  Future<Uri> createRechargeOrder(double amountYuan) async {
    if (_token == null) await _loginCard();
    try {
      return await _createOrder(amountYuan);
    } on CardAuthExpired {
      _token = null;
      await _loginCard();
      return _createOrder(amountYuan);
    }
  }

  Future<Uri> _createOrder(double amountYuan) async {
    Response res;
    try {
      final signed = signPayload({
        'feeitemid': _feeItemId,
        'appid': _payAppId,
        'tranamt': amountYuan,
        'source': 'app',
        'synjones-auth': 'bearer $_token',
        'yktcard': (await _queryCard()).account,
        'synAccessSource': 'h5',
        'abstracts': '{"type":"recharge"}',
      });
      res = await dio.post('$_base/charge/order/thirdOrder',
          data: signed,
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            // 平台对签名/参数错误也可能回 JSON，读得到 body 才好报错
            validateStatus: (c) => c != null && c < 500,
          ));
    } on DioException catch (e) {
      // 网络层错误转可读文案（默认 toString 在混淆下不可读）
      throw CardAuthFailed('网络错误：${e.message ?? e.type.name}');
    }
    final loc = res.headers.value('location');
    if (loc != null) {
      final cashier = Uri.parse(_abs(_base, loc));
      if (cashier.queryParameters['orderid']?.isNotEmpty == true) {
        return cashier;
      }
    }
    // 没有 302：读 JSON 业务错误（若有）
    if (res.data is Map) {
      final body = res.data as Map;
      if (body['code'] == 401) throw const CardAuthExpired();
      throw CardAuthFailed(
          '下单失败：${body['msg'] ?? body['message'] ?? body['error'] ?? '未知错误'}');
    }
    throw const CardAuthFailed('下单失败：服务端未返回收银台地址');
  }

  /// 支付订单实时状态。paystatus 初值在创建后立刻记录，轮询比对变化即视为已支付。
  Future<({String orderid, String paystatus, String? alipayPayid, String? weixinPayid})> getPayInfo(Uri cashierUrl) async {
    final orderid = cashierUrl.queryParameters['orderid'];
    if (orderid == null || orderid.isEmpty) {
      throw const CardAuthFailed('订单号缺失');
    }
    final token = cashierUrl.queryParameters['token'] ?? _token ?? '';
    final res = await dio.get('$_base/charge/pay/getpayinfo',
        queryParameters: {'orderid': orderid, 'synAccessSource': 'h5'},
        options: _opts(headers: {'synjones-auth': 'bearer $token'}));
    final body = _body(res, '查询订单');
    final order = body['order'] as Map? ?? {};
    final payList = body['payList'] as List? ?? [];
    String? alipayPayid, weixinPayid;
    for (final p in payList) {
      if (p is! Map) continue;
      if ('${p['name']}' == '支付宝') alipayPayid = '${p['payid']}';
      if ('${p['name']}' == '微信') weixinPayid = '${p['payid']}';
    }
    return (
      orderid: orderid,
      paystatus: '${order['paystatus']}',
      alipayPayid: alipayPayid,
      weixinPayid: weixinPayid,
    );
  }

  /// 复刻网页签名（chunk-7d526474 模块 89eb 的 f 函数）：
  /// 注入 APP_ID/TIMESTAMP/SIGN_TYPE/NONCE，把全部字段按 key 升序拼成
  /// `k=v&`（跳过 SIGN/SECRET_KEY 与空值，保留 0），尾部接
  /// `SECRET_KEY=<secret>`（无 &），SHA256 后转大写写入 SIGN。
  /// [timestamp]/[nonce] 仅供测试注入；线上用当前时间与随机串。
  static Map<String, String> signPayload(Map<String, Object?> data,
      {String? timestamp, String? nonce}) {
    final payload = <String, String>{
      for (final e in data.entries)
        if (e.value != null) e.key: _jsStr(e.value!),
      'APP_ID': _payAppId,
      'TIMESTAMP': timestamp ?? _timestamp(),
      'SIGN_TYPE': 'SHA256',
      'NONCE': nonce ?? _nonce(),
    };
    final keys = payload.keys
        .where((k) => k != 'SIGN' && k != 'SECRET_KEY')
        .toList()
      ..sort();
    final buf = StringBuffer();
    for (final k in keys) {
      final v = payload[k];
      if (v == null || v.isEmpty) continue; // 与 JS `v || v === 0` 口径一致
      buf.write('$k=$v&');
    }
    buf.write('SECRET_KEY=$_paySecret');
    final sign =
        sha256.convert(utf8.encode(buf.toString())).toString().toUpperCase();
    payload['SIGN'] = sign;
    return payload;
  }

  /// yyyyMMddHHmmss（与网页一致，不带毫秒）
  static String _timestamp() {
    final t = DateTime.now();
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${p2(t.month)}${p2(t.day)}'
        '${p2(t.hour)}${p2(t.minute)}${p2(t.second)}';
  }

  static String _nonce() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rnd = Random.secure();
    return List.generate(11, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  /// JS Number→string 口径：整数不带小数点（10.0 -> "10"，10.5 -> "10.5"）。
  /// 网页把金额作为 JS number 拼进签名串和表单，Dart 必须对齐这个口径。
  static String _jsStr(Object v) {
    if (v is double) {
      return v == v.roundToDouble() ? v.toInt().toString() : '$v';
    }
    return '$v';
  }

  /// CAS SSO → 加密 ticket → JWT
  Future<void> _loginCard() async {
    final ticket = await _casTicket();
    final res = await dio.post(
      '$_base/berserker-auth/oauth/token',
      data: {
        // 与网页 login.js getToken() 逐字段一致：ticket 同时充当用户名和密码
        'username': ticket,
        'password': ticket,
        'grant_type': 'password',
        'scope': 'all',
        'loginFrom': 'h5',
        'logintype': 'sso',
        'device_token': 'h5',
      },
      options: _opts(headers: {
        'Content-Type': Headers.formUrlEncodedContentType,
        'Authorization': _basicAuth,
      }),
    );
    final body = res.data;
    final token = body is Map ? body['access_token'] as String? : null;
    if (token == null || token.isEmpty) {
      final msg = body is Map
          ? (body['message'] ?? body['error'] ?? '未知错误').toString()
          : 'HTTP ${res.statusCode}';
      throw CardAuthFailed('一卡通登录失败：$msg');
    }
    _token = token;
  }

  /// 走 CAS SSO 链拿 berserker 加密 ticket。
  /// 解码口径：Location 上的值是双重百分号编码，解码一次即网页
  /// getRequest(decodeURIComponent) 拿到的值（+ 号保留，不能用 queryParameters）。
  Future<String> _casTicket() async {
    // service 整体编码（与浏览器跳转一致，% 二次编码），CAS 会在其后拼 &ticket=ST-xxx
    var current =
        'http://authserver.nuaa.edu.cn/authserver/login?service='
        '${Uri.encodeQueryComponent(_service)}';
    for (var hop = 0; hop < 10; hop++) {
      final res = await dio.get(current);
      final status = res.statusCode ?? 0;
      final loc = res.headers.value('location');
      if (status >= 300 && status < 400 && loc != null) {
        current = _abs(current, loc);
        // berserker 校验 ST 后 302 回 plat，Location 上带加密 ticket
        if (current.contains('/plat/') && current.contains('ticket=')) {
          final t = _queryParam(current, 'ticket');
          if (t != null && t.isNotEmpty && !t.startsWith('ST-')) return t;
        }
        continue;
      }
      // 跟完仍落在 authserver 登录页 = SSO 会话不存在，需密码重登
      if (Uri.parse(current).host.contains('authserver')) {
        throw SessionExpired();
      }
      throw const CardAuthFailed('一卡通登录链路异常：未拿到 ticket');
    }
    throw const CardAuthFailed('一卡通登录重定向次数过多');
  }

  Future<CardUser> _user() async {
    final res = await dio.get('$_base/berserker-base/user',
        options: _opts(headers: _authHeader()));
    final body = _body(res, '获取用户信息');
    final data = body['data'];
    if (data is! Map) throw const CardAuthFailed('一卡通用户信息为空');
    return CardUser(
      (data['name'] ?? '').toString(),
      (data['sno'] ?? '').toString(),
      (data['cardAccount'] ?? '').toString(),
    );
  }

  Future<PayCodeBatch> _codes(String cardAccount) async {
    final res = await dio.get(
      '$_base/berserker-app/ykt/tsm/batchGetBarCodeGet',
      queryParameters: {
        'account': cardAccount,
        'payacc': '000',
        'paytype': '1',
        'synAccessSource': 'h5',
      },
      options: _opts(headers: _authHeader()),
    );
    final body = _body(res, '获取付款码');
    final data = body['data'];
    if (data is! Map) throw const CardAuthFailed('付款码数据为空');
    final codes = (data['barcode'] as List? ?? []).map((e) => e.toString()).toList();
    if (codes.isEmpty) {
      throw CardAuthFailed(
          '未取到付款码：${data['errmsg'] ?? body['msg'] ?? '服务端返回为空'}');
    }
    return PayCodeBatch(
      codes: codes,
      expiresSeconds: int.tryParse('${data['expires']}') ?? 120,
    );
  }

  Map<dynamic, dynamic> _body(Response res, String what) {
    final body = res.data;
    if (body is! Map) throw CardAuthFailed('$what失败：HTTP ${res.statusCode}');
    final code = body['code'];
    if (code == 401) throw const CardAuthExpired();
    if (code != 200) throw CardAuthFailed('$what失败：${body['msg'] ?? body['message'] ?? code}');
    return body;
  }

  /// 只做百分号解码的 query 取值（+ 号是 ticket 字符的一部分，不能用
  /// Uri.queryParameters——它会把 + 解成空格）
  static String? _queryParam(String url, String name) {
    final query = Uri.parse(url).query;
    for (final pair in query.split('&')) {
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      if (Uri.decodeComponent(pair.substring(0, eq)) == name) {
        return Uri.decodeComponent(pair.substring(eq + 1));
      }
    }
    return null;
  }

  String _abs(String base, String loc) {
    if (loc.startsWith('http://') || loc.startsWith('https://')) return loc;
    final b = Uri.parse(base);
    final root = '${b.scheme}://${b.host}${b.hasPort ? ':${b.port}' : ''}';
    return loc.startsWith('/') ? '$root$loc' : '$root/$loc';
  }
}
