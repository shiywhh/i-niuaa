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
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 仓库（owner/repo）：releases 页与 API 都从这拼
const repoSlug = 'shiywhh/i-niuaa';
const releasesUrl = 'https://github.com/$repoSlug/releases';

/// 下载镜像源：prefix 拼在 browser_download_url 前面
class DownloadMirror {
  final String key;
  final String name;
  final String? prefix;
  const DownloadMirror(this.key, this.name, this.prefix);

  String urlFor(String githubUrl) =>
      prefix == null ? githubUrl : '$prefix$githubUrl';
}

/// 顺序即手动列表顺序；直连永远在列（测速失败时也可兜底再试）
const downloadMirrors = <DownloadMirror>[
  DownloadMirror('direct', 'GitHub 直连', null),
  DownloadMirror('ghfast', 'ghfast.top', 'https://ghfast.top/'),
  DownloadMirror('ghproxy', 'gh-proxy.com', 'https://gh-proxy.com/'),
  DownloadMirror('moeyy', 'Moeyy 加速', 'https://github.moeyy.xyz/'),
];

DownloadMirror? mirrorByKey(String key) {
  for (final m in downloadMirrors) {
    if (m.key == key) return m;
  }
  return null;
}

/// 按模式排出尝试顺序：auto = 测速结果（快->慢）在前、失败的兜底在后；
/// 手动 = 选中的镜像优先，其余照测速/默认顺序跟上
List<DownloadMirror> orderMirrorsFor(String mode, List<DownloadMirror> ranked) {
  final chosen = mode == 'auto' ? null : mirrorByKey(mode);
  return [
    ?chosen,
    ...ranked.where((m) => m.key != chosen?.key),
    ...downloadMirrors.where(
      (m) => m.key != chosen?.key && ranked.every((r) => r.key != m.key),
    ),
  ];
}

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

/// 自动检查更新开关（启动时静默检查用）
class UpdateSettings {
  UpdateSettings._();
  static final instance = UpdateSettings._();

  static const _key = 'update_auto_check_v1';
  static const _mirrorKey = 'update_mirror_v1';

  final ValueNotifier<int> revision = ValueNotifier(0);
  var autoCheck = true;

  /// 'auto'（测速选最快）或某个镜像 key
  var mirrorMode = 'auto';

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      autoCheck = p.getBool(_key) ?? true;
      mirrorMode = p.getString(_mirrorKey) ?? 'auto';
    } catch (_) {}
    revision.value++;
  }

  Future<void> setAutoCheck(bool value) async {
    autoCheck = value;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_key, value);
    } catch (_) {}
    revision.value++;
  }

  Future<void> setMirrorMode(String value) async {
    mirrorMode = value;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_mirrorKey, value);
    } catch (_) {}
    revision.value++;
  }
}

/// 启动静默检查：开关关着 / 无新版 / 网络失败 一律返回 null（不抛）
Future<ReleaseInfo?> silentCheckForUpdate() async {
  if (!UpdateSettings.instance.autoCheck) return null;
  try {
    final release = await fetchLatestRelease();
    final info = await PackageInfo.fromPlatform();
    return isNewer(info.version, release.tag) ? release : null;
  } catch (_) {
    return null;
  }
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

/// 单镜像测速：Range 拉 128KB 计时（毫秒），失败返回 null
Future<int?> probeMirror(String githubUrl, DownloadMirror m) async {
  final sw = Stopwatch()..start();
  try {
    final res =
        await Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 6),
                headers: {'User-Agent': 'i-niuaa', 'Range': 'bytes=0-131071'},
              ),
            )
            .get<List<int>>(
              m.urlFor(githubUrl),
              options: Options(responseType: ResponseType.bytes),
            )
            .timeout(const Duration(seconds: 10));
    sw.stop();
    if (res.data == null || res.data!.isEmpty) return null;
    return sw.elapsedMilliseconds;
  } catch (_) {
    return null;
  }
}

/// 并行测速全部镜像，返回可达镜像按快 -> 慢排序
Future<List<DownloadMirror>> rankMirrors(String githubUrl) async {
  final results = await Future.wait(
    downloadMirrors.map(
      (m) async => MapEntry(m, await probeMirror(githubUrl, m)),
    ),
  );
  final ok = results.where((e) => e.value != null).toList()
    ..sort((a, b) => a.value!.compareTo(b.value!));
  return ok.map((e) => e.key).toList();
}

/// 按镜像顺序下载：auto 先并行测速选最快，手动则选中源优先；
/// 任一源失败自动换下一家。成功返回实际使用的镜像，全部失败抛异常
Future<DownloadMirror> downloadPackageWithMirror({
  required String githubUrl,
  required String savePath,
  required String mirrorMode,
  void Function(int received, int total)? onProgress,
  void Function(String mirrorName)? onMirror,
  CancelToken? cancelToken,
}) async {
  final ranked = mirrorMode == 'auto'
      ? await rankMirrors(githubUrl)
      : const <DownloadMirror>[];
  final order = orderMirrorsFor(mirrorMode, ranked);
  for (final m in order) {
    if (cancelToken?.isCancelled ?? false) {
      throw DioException(
        requestOptions: RequestOptions(path: githubUrl),
        type: DioExceptionType.cancel,
      );
    }
    onMirror?.call(m.name);
    try {
      await downloadPackage(
        m.urlFor(githubUrl),
        savePath,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
      return m;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) rethrow;
      // 换下一个源
    }
  }
  throw const FormatException('所有下载源均下载失败');
}
