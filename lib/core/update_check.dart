// Engine | Flutter 3.x / Dart 3 | lib/core/update_check.dart
// 检查更新：GitHub Releases API 拉最新版 tag，与本地版本逐段比较。
//   - 比较函数纯 Dart 可单测；tag 兼容带/不带 v 前缀，段数不足补 0
//   - 网络用独立 Dio（不带教务会话 cookie，超时从紧）
// Deps: dio

import 'package:dio/dio.dart';

/// 仓库（owner/repo）：releases 页与 API 都从这拼
const repoSlug = 'shiywhh/i-niuaa';
const releasesUrl = 'https://github.com/$repoSlug/releases';

/// 一个 release 的摘要（只用 tag/链接/说明三个字段）
class ReleaseInfo {
  final String tag; // tag_name，如 'v2.1.0'
  final String url; // html_url，下载页
  final String notes; // body，release 说明（可能为空）
  const ReleaseInfo(this.tag, this.url, this.notes);
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

/// 拉最新 release；网络失败 / 限流 / 还没发过 release（404）都抛异常，
/// 由调用方统一提示
Future<ReleaseInfo> fetchLatestRelease({Dio? dio}) async {
  final client =
      dio ??
      Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
  final res = await client.get<Map<String, dynamic>>(
    'https://api.github.com/repos/$repoSlug/releases/latest',
    options: Options(
      headers: {
        'Accept': 'application/vnd.github+json',
        // 匿名配额 60 次/时/IP；带 UA 与 Accept 减少被拒概率
        'User-Agent': 'i-niuaa',
      },
    ),
  );
  final data = res.data;
  if (data == null) {
    throw const FormatException('release 数据为空');
  }
  final tag = data['tag_name'];
  if (tag is! String || tag.isEmpty) {
    throw const FormatException('release 数据缺 tag_name');
  }
  return ReleaseInfo(
    tag,
    data['html_url'] is String ? data['html_url'] as String : releasesUrl,
    data['body'] is String ? data['body'] as String : '',
  );
}
