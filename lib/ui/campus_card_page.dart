// Engine | Flutter 3.x / Dart 3 | lib/ui/campus_card_page.dart
// 校园卡页 = 身份码（动态付款码）+ 卡片充值 合并。
// 上半部分是付款码：服务端一批下发、每 expires 秒切换，批次用尽自动重取；
// 下半部分是充值：queryCard 余额 + 签名下单，收银台交给 CashierPage
// （Android/iOS 内置 webview，可拦截支付结果自动返回；桌面跳外部浏览器）。

import 'dart:async';
import 'dart:io';

import 'package:barcode_widget/barcode_widget.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/card_client.dart' show CardAuthExpired, CardAuthFailed, CardUser;
import '../core/eams_client.dart' show SessionExpired;
import '../core/models.dart';
import '../core/session.dart';

class CampusCardPage extends StatefulWidget {
  const CampusCardPage({super.key});

  @override
  State<CampusCardPage> createState() => _CampusCardPageState();
}

class _CampusCardPageState extends State<CampusCardPage> {
  static const _quickAmounts = [10.0, 50.0, 100.0];

  final _amountCtrl = TextEditingController();

  PayCodeBatch? _batch;
  CardUser? _user;
  RechargeAccount? _acct;
  Object? _codeErr;
  Object? _acctErr;
  bool _loading = false;
  bool _submitting = false;
  Timer? _pollTimer;
  int _pollLeft = 0;
  String? _payStatus;
  bool _reveal = false;
  DateTime _now = DateTime.now();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _load();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pollTimer?.cancel();
    _amountCtrl.dispose();
    super.dispose();
  }

  void _tick() {
    if (!mounted) return;
    setState(() => _now = DateTime.now());
    // 批次用尽：静默重取（页面继续展示旧码，取到后无缝替换）
    final b = _batch;
    if (b != null && b.indexAt(DateTime.now()) < 0 && !_loading) {
      _loadCodesOnly();
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _codeErr = null;
      _acctErr = null;
    });
    // 两条链路独立容错：付款码挂了不该连余额一起看不到
    Object? codeErr;
    Object? acctErr;
    (PayCodeBatch, CardUser)? codes;
    RechargeAccount? acct;
    try {
      codes = await Session.I.guard(() => Session.I.card.fetchAll());
    } catch (e) {
      codeErr = _fmtError(e);
    }
    try {
      acct = await Session.I.guard(() => Session.I.card.queryRechargeAccount());
    } catch (e) {
      acctErr = _fmtError(e);
    }
    if (!mounted) return;
    setState(() {
      _batch = codes?.$1;
      _user = codes?.$2;
      _acct = acct;
      _codeErr = codes == null ? codeErr : null;
      _acctErr = acct == null ? acctErr : null;
      _now = DateTime.now();
      _loading = false;
    });
  }

  /// 付款码批次用尽时的静默补拉：不打转圈、不清余额
  Future<void> _loadCodesOnly() async {
    try {
      final (batch, user) =
          await Session.I.guard(() => Session.I.card.fetchAll());
      if (!mounted) return;
      setState(() {
        _batch = batch;
        _user = user;
        _codeErr = null;
      });
    } catch (_) {/* 下个 tick 再试 */}
  }

  double? get _amount {
    final v = double.tryParse(_amountCtrl.text.trim());
    return (v == null || v <= 0) ? null : v;
  }

  Future<void> _submit() async {
    final acct = _acct;
    final amount = _amount;
    if (acct == null || amount == null || _submitting) return;
    if (acct.lostFlag) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('卡已挂失，无法充值，请先解挂')));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认充值'),
        content: Text('向 ${acct.cardName}（${acct.account}）充值 '
            '￥${amount.toStringAsFixed(2)}？\n\n'
            '将打开浏览器完成支付。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('去支付'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _submitting = true);
    Uri? cashier;
    Object? err;
    try {
      cashier = await Session.I.guard(
          () => Session.I.card.createRechargeOrder(amount));
    } catch (e) {
      err = _fmtError(e);
    }
    if (!mounted) return;
    setState(() => _submitting = false);
    if (err != null || cashier == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err?.toString() ?? '下单失败')));
      return;
    }

    // 系统浏览器打开收银台（确认支付页自带支付宝/微信选择；
    // 微信渠道从该页发起时 referer 正确，可正常唤起微信付款）
    final launched = await _launchExternal(cashier);
    if (!mounted) return;
    if (!launched) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('浏览器打开失败，请检查系统浏览器')));
      return;
    }

    // 后台轮询先行（3 分钟内付款完成会自动刷新），同时弹窗确认
    _startPolling(cashier);
    final paid = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('支付确认'),
        content: const Text('是否已完成支付？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('暂未完成'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('已完成'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (paid == true) {
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('余额已刷新')));
    }

    // 轮询订单状态：支付完成自动刷新（最多 ~3 分钟）
    _startPolling(cashier);
  }

  /// 每 3 秒查一次订单状态，paystatus 变化即视为支付成功
  void _startPolling(Uri cashier) {
    _pollTimer?.cancel();
    _pollLeft = 40;
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (t) async {
      _pollLeft--;
      if (_pollLeft <= 0 || !mounted) {
        t.cancel();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('若已完成支付，请下拉刷新余额查看')));
        }
        return;
      }
      try {
        final now = await Session.I.card.getPayInfo(cashier);
        final cur = _payStatus;
        if (cur != null && now.paystatus != cur) {
          t.cancel();
          if (!mounted) return;
          setState(() => _payStatus = now.paystatus);
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('支付成功，余额已刷新')));
          _load();
        }
      } catch (_) {/* 网络抖动忽略，下轮再试 */}
    });
  }

  /// 异常 → 用户可读文案（混淆包里 toString 不可读）
  static String _fmtError(Object e) {
    if (e is CardAuthFailed || e is CardAuthExpired) return e.toString();
    if (e is SessionExpired) return e.toString();
    if (e is DioException) return '网络错误：${e.message ?? e.type.name}';
    return '出错了：$e'; // 未知异常，直接显示便于排查
  }

  /// 40063832... -> 4006 3832 ...（每 5 位一组，与网页展示一致）
  static String _group(String code) {
    final buf = StringBuffer();
    for (var i = 0; i < code.length; i += 5) {
      if (i > 0) buf.write(' ');
      final end = (i + 5).clamp(0, code.length);
      buf.write(code.substring(i, end));
    }
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 全军覆没才上整页错误；单侧失败在对应区块内提示
    if (_codeErr != null && _acctErr != null && _batch == null && _acct == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.credit_card_off, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              Text('加载失败：$_codeErr', textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_batch == null && _acct == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final batch = _batch;
    final code = batch?.codeAt(_now);
    final idx = batch?.indexAt(_now) ?? -1;
    final left = batch?.secondsLeftAt(_now) ?? 0;
    final acct = _acct;
    final user = _user;

    return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            // ── 卡片头部：持卡人 ──
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.account_balance_wallet, color: Colors.white),
                  const SizedBox(width: 10),
                  Text(
                    '${acct?.name ?? user?.name ?? ''}  ${user?.sno ?? acct?.account ?? ''}',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(color: Colors.white),
                  ),
                  const Spacer(),
                  Text(acct?.cardName ?? '一账通',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Colors.white70)),
                ],
              ),
            ),
            // ── 余额 ──
            Container(
              width: double.infinity,
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: acct == null
                  ? _balanceErrorRow(theme)
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text('账户余额', style: theme.textTheme.bodySmall),
                        const SizedBox(width: 10),
                        Text(acct.balanceYuan.toStringAsFixed(2),
                            style: theme.textTheme.headlineMedium),
                        const SizedBox(width: 4),
                        Text('元', style: theme.textTheme.bodySmall),
                        if (acct.lostFlag) ...[
                          const SizedBox(width: 12),
                          Text('已挂失',
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.error)),
                        ],
                      ],
                    ),
            ),
            // ── 付款码 ──（条形码 + 数字 + 二维码 + 倒计时）
            if (code != null) ...[
              Container(
                width: double.infinity,
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
                child: Column(
                  children: [
                    BarcodeWidget(
                      barcode: Barcode.code128(),
                      data: code,
                      height: 80,
                      width: double.infinity,
                      drawText: false,
                      backgroundColor: Colors.white,
                    ),
                    const SizedBox(height: 10),
                    InkWell(
                      onTap: () => setState(() => _reveal = !_reveal),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _reveal
                                ? _group(code)
                                : '${code.substring(0, 4)} ******',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(width: 6),
                          Icon(
                            _reveal ? Icons.visibility_off : Icons.visibility,
                            size: 18,
                            color: theme.colorScheme.primary,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: double.infinity,
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                child: Column(
                  children: [
                    BarcodeWidget(
                      barcode: Barcode.qrCode(),
                      data: code,
                      width: 190,
                      height: 190,
                      backgroundColor: Colors.white,
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.timer_outlined,
                            size: 16, color: theme.colorScheme.primary),
                        const SizedBox(width: 4),
                        Text(
                          '第 ${idx + 1}/${batch!.codes.length} 个 · ${left}s 后自动刷新',
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(width: 12),
                        InkWell(
                          onTap: _loading ? null : _loadCodesOnly,
                          child: _loading
                              ? const SizedBox(
                                  width: 14, height: 14,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : Icon(Icons.refresh,
                                  size: 18, color: theme.colorScheme.primary),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ] else
              Container(
                width: double.infinity,
                color: Colors.white,
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Text('付款码加载失败：$_codeErr',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: _loadCodesOnly,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
            // ── 卡片圆角收尾 ──
            Container(
              height: 10,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius:
                    const BorderRadius.vertical(bottom: Radius.circular(16)),
              ),
            ),
            const SizedBox(height: 16),
            if (code != null)
              Text(
                '付款码用于向商家付款或核验身份，仅限本人出示，请勿发送给他人。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            if (code != null) const SizedBox(height: 20),
            // ── 充值 ──
            Text('卡片充值（元）', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _amountCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                prefixText: '￥ ',
                hintText: '请输入金额',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final a in _quickAmounts)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ActionChip(
                        label: Center(child: Text('${a.toInt()}元')),
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          _amountCtrl.text = a.toInt().toString();
                          setState(() {});
                        },
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: (acct != null &&
                      _amount != null &&
                      !acct.lostFlag &&
                      !_submitting)
                  ? _submit
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: _submitting
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('立即充值'),
              ),
            ),
            const SizedBox(height: 12),
            // ── 电费/网费：wisedu 端只对 i南航 通道开放，圆形按钮跳转 ──
            if (Platform.isAndroid || Platform.isIOS) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _roundJump(Icons.bolt, '电费充值',
                      'https://m.nuaa.edu.cn/site/nuaaElectric/index'),
                  _roundJump(Icons.wifi, '网费充值',
                      'https://m.nuaa.edu.cn/site/nuaawfcz/index'),
                ],
              ),
              const SizedBox(height: 8),
              Text('点击跳转i南航',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            ],
            const SizedBox(height: 12),
          ],
        ));
  }

  Future<bool> _launchExternal(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  /// 跳转 i南航：
  /// 1) 优先 nuaaapp://nuaa/web?WEB_PARAMETER_URL=... —— i南航内置浏览器
  ///    直接打开目标页（其 WebView 带 eai-sess 登录态，校外可用）；
  /// 2) 失败退「全部应用」页；3) 再失败退主页；都没有 = 未安装。
  Future<void> _openInIApp(String targetUrl, String title) async {
    final links = [
      Uri.parse('nuaaapp://nuaa/web').replace(queryParameters: {
        'WEB_PARAMETER_URL': targetUrl,
        'WEB_PARAMETER_TITLE': title,
      }).toString(),
      'nuaaapp://nuaa/module_all_v2',
      'nuaaapp://nuaa/home',
    ];
    for (final u in links) {
      try {
        final ok = await launchUrl(Uri.parse(u),
            mode: LaunchMode.externalApplication);
        if (ok) return;
      } catch (_) {
        // 未安装/未注册 scheme，试下一个
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未检测到 i南航，请先安装')));
    }
  }

  Widget _roundJump(IconData icon, String label, String targetUrl) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Material+CircleBorder 让水波纹严格裁剪在圆形内
        Material(
          color: theme.colorScheme.primary.withValues(alpha: 0.12),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _openInIApp(targetUrl, label),
            child: SizedBox(
              width: 52,
              height: 52,
              child: Icon(icon, size: 26, color: theme.colorScheme.primary),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }

  Widget _balanceErrorRow(ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('余额查询失败', style: theme.textTheme.bodySmall),
        const SizedBox(width: 8),
        InkWell(
          onTap: _loading ? null : _load,
          child: Icon(Icons.refresh,
              size: 18, color: theme.colorScheme.primary),
        ),
      ],
    );
  }
}
