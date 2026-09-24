// Engine | Flutter 3.x / Dart 3 | lib/core/app_updater.dart
// 应用内更新：GitHub Releases 拉最新版信息（含资产清单），发现新版后
// 在应用内下载安装包并拉起安装。
//   - 比较函数纯 Dart 可单测；tag 兼容带/不带 v 前缀，段数不足补 0
//   - 网络用独立 Dio（不带教务会话 cookie，超时从紧；下载走流式进度）
//   - 资产下载直连 browser_download_url（github.com）；失败由调用方
//     降级为"前往下载页"，不做第三方镜像代理
// Deps: dio

import 'dart:io';

import 'package:dio/dio.dart';

/// 仓库（owner/repo）：releases 页与 API 都从这拼
const repoSlug = 'shiywhh/i-niuaa';
const releasesUrl = 'https://github.com/$repoSlug/releases';

/// 一个 release 资产（安装包）
class ReleaseAsset {
  final String name;
  final String url; // browser_download_url
  final int size;
  const ReleaseAsset(this.name, this.url, this.size);
}

/// 一个 release 的摘要
class ReleaseInfo {
  final String tag; // tag_name，如 'v2.1.0'
  final String url; // html_url，下载页
  final String notes; // body，release 说明（可能为空）
  final List<ReleaseAsset> assets;
  const ReleaseInfo(this.tag, this.url, this.notes, this.assets);

  /// 平台对应的安装包：Android 取 .apk，桌面取 .exe；没有返回 null
  ReleaseAsset? packageAsset({required bool android}) {
    final ext = android ? '.apk' : '.exe';
    for (final a in assets) {
      if (a.name.toLowerCase().endsWith(ext)) return a;
    }
    return null;
  }
}

/// 'v2.10.3' / '2.10.3' -> [2, 10, 3]；含非数字段返回 null
List<int>? parseVersion(String v) {
  final s = v.trim().replaceFirst(RegExp(r'^[vV]'), '');
  if (s.isEmpty) return null;
  final out = <int>[];
  for (final p in s.split('.')) {
    final n = int.tryParse(p);
    if (n == null) return null;
    out.add(n);
  }
  return out.isEmpty ? null : out;
}

/// [latest] 是否比 [current] 新：逐段数值比较（10 > 9，非字典序），
/// 段数不足补 0；任一侧解析失败返回 false（宁可不提示，不误报）
bool isNewer(String current, String latest) {
  final a = parseVersion(current);
  final b = parseVersion(latest);
  if (a == null || b == null) return false;
  final n = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (y != x) return y > x;
  }
  return false;
}

Dio _apiDio() => Dio(
  BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 8),
    headers: {
      'Accept': 'application/vnd.github+json',
      // 匿名配额 60 次/时/IP；带 UA 与 Accept 减少被拒概率
      'User-Agent': 'i-niuaa',
    },
  ),
);

/// 拉最新 release（含资产清单）；网络失败 / 限流 / 还没发过 release
/// （404）都抛异常，由调用方统一提示
Future<ReleaseInfo> fetchLatestRelease() async {
  final res = await _apiDio().get<Map<String, dynamic>>(
    'https://api.github.com/repos/$repoSlug/releases/latest',
  );
  final data = res.data;
  if (data == null) {
    throw const FormatException('release 数据为空');
  }
  final tag = data['tag_name'];
  if (tag is! String || tag.isEmpty) {
    throw const FormatException('release 数据缺 tag_name');
  }
  final assets = <ReleaseAsset>[
    for (final a in (data['assets'] as List? ?? const []))
      if (a is Map &&
          a['name'] is String &&
          a['browser_download_url'] is String)
        ReleaseAsset(
          a['name'] as String,
          a['browser_download_url'] as String,
          (a['size'] as num?)?.toInt() ?? 0,
        ),
  ];
  return ReleaseInfo(
    tag,
    data['html_url'] is String ? data['html_url'] as String : releasesUrl,
    data['body'] is String ? data['body'] as String : '',
    assets,
  );
}

/// 下载安装包到 [savePath]（直连 browser_download_url，会经历
/// github.com -> objects.githubusercontent.com 重定向）。
/// [onProgress] 收到 (已收字节, 总字节)；总字节未知时为 0。
/// [cancelToken] 用于进度对话框里的取消
Future<void> downloadPackage(
  String url,
  String savePath, {
  void Function(int received, int total)? onProgress,
  CancelToken? cancelToken,
}) async {
  await Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      headers: {'User-Agent': 'i-niuaa'},
    ),
  ).download(
    url,
    savePath,
    onReceiveProgress: onProgress,
    cancelToken: cancelToken,
    options: Options(responseType: ResponseType.bytes),
  );
  if (!File(savePath).existsSync() || File(savePath).lengthSync() == 0) {
    throw const FormatException('下载内容为空');
  }
}
