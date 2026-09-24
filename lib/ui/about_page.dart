// Engine | Flutter 3.x / Dart 3 | lib/ui/about_page.dart
// 关于页（tab 栏最后一项）：版本信息、检查更新（含自动检查开关；
// 应用内下载安装：Android 拉起系统安装器 / Windows 直接启动安装包）、
// 仓库链接、数据来源、免责声明、开源许可（LicensePage）。
//   - 发现新版本的弹窗/下载流程抽成顶层函数，HomeShell 的启动
//     静默检查复用同一入口
//   - 下载直连 GitHub browser_download_url，失败可降级"前往下载页"
//   - Android 首次安装需在系统弹窗中授权"允许安装未知应用"
// Deps: package_info_plus, url_launcher, dio, open_filex, path_provider,
//       flutter_markdown_plus

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_updater.dart';

/// 系统浏览器打开链接，失败给轻提示
Future<void> openExternal(BuildContext context, String url) async {
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开链接')),
      );
    }
  }
}

/// "发现新版本"弹窗：说明（markdown）+ 应用内下载 / 前往下载页。
/// 启动静默检查命中新版时也走这里
Future<void> showUpdateAvailableDialog(
  BuildContext context,
  ReleaseInfo release,
) async {
  final info = await PackageInfo.fromPlatform();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('发现新版本 ${release.tag}'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '当前版本 v${info.version}，建议更新到 ${release.tag}。',
              style: const TextStyle(fontSize: 13),
            ),
            if (release.notes.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: MarkdownBody(
                    data: release.notes.trim(),
                    selectable: true,
                    styleSheet: MarkdownStyleSheet.fromTheme(
                      Theme.of(context),
                    ).copyWith(
                      p: const TextStyle(fontSize: 12.5, height: 1.35),
                      listBullet: const TextStyle(
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                      h1: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.bold,
                      ),
                      h2: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.bold,
                      ),
                      code: const TextStyle(
                        fontSize: 11.5,
                        backgroundColor: Color(0x14000000),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('稍后'),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(ctx);
            openExternal(context, release.url);
          },
          child: const Text('前往下载页'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(ctx);
            downloadAndInstall(context, release);
          },
          child: Text(Platform.isAndroid ? '下载安装' : '下载更新'),
        ),
      ],
    ),
  );
}

/// 应用内下载并拉起安装：
///   Android -> 应用专属外部目录 + open_filex 拉起系统安装器
///   Windows -> 下载目录 + 独立进程启动 Inno 安装包（走 UAC）
Future<void> downloadAndInstall(
  BuildContext context,
  ReleaseInfo release,
) async {
  final asset = release.packageAsset(android: Platform.isAndroid);
  if (asset == null) {
    openExternal(context, release.url); // 资产缺失兜底：去下载页
    return;
  }
  if (!context.mounted) return;

  // 保存位置：Android 用应用专属外部目录（无需存储权限），
  // Windows 优先下载目录，兜底临时目录
  String dirPath;
  if (Platform.isAndroid) {
    final dirs = await getExternalStorageDirectories();
    dirPath = dirs?.first.path ?? (await getTemporaryDirectory()).path;
  } else if (Platform.isWindows) {
    dirPath =
        (await getDownloadsDirectory())?.path ??
        (await getTemporaryDirectory()).path;
  } else {
    dirPath = (await getTemporaryDirectory()).path;
  }
  final file = File('$dirPath/${asset.name}');
  if (file.existsSync()) file.deleteSync(); // 旧包清掉重下
  if (!context.mounted) return;

  // 进度对话框（不可点外部关闭，可取消）
  final token = CancelToken();
  final progress = ValueNotifier<List<int>>(const [0, 0]); // [已收, 总]
  var dialogOpen = true;
  BuildContext? dialogCtx;

  /// 幂等关闭进度框：取消按钮和下载收尾都可能触发，只允许弹一次，
  /// 否则二次 pop 会把根路由弹掉（黑屏）
  void closeProgress() {
    if (!dialogOpen) return;
    dialogOpen = false;
    final ctx = dialogCtx;
    if (ctx != null && ctx.mounted) Navigator.pop(ctx);
  }

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      dialogCtx = ctx;
      return AlertDialog(
        title: Text('下载 ${asset.name}'),
        content: ValueListenableBuilder<List<int>>(
          valueListenable: progress,
          builder: (_, v, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: v[1] > 0 ? v[0] / v[1] : null),
              const SizedBox(height: 10),
              Text(
                v[1] > 0
                    ? '${(v[0] / 1048576).toStringAsFixed(1)} / '
                        '${(v[1] / 1048576).toStringAsFixed(1)} MB'
                    : '${(v[0] / 1048576).toStringAsFixed(1)} MB',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              token.cancel('用户取消');
              closeProgress();
            },
            child: const Text('取消'),
          ),
        ],
      );
    },
  );

  String? failure;
  try {
    await downloadPackage(
      asset.url,
      file.path,
      onProgress: (r, t) => progress.value = [r, t],
      cancelToken: token,
    );
  } on DioException catch (e) {
    if (e.type != DioExceptionType.cancel) {
      failure = '下载失败，请检查网络后重试，或改用「前往下载页」';
    }
  } catch (_) {
    failure = '下载失败，请检查网络后重试，或改用「前往下载页」';
  }
  closeProgress();
  if (failure != null) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(failure)));
    }
    return;
  }

  // 拉起安装
  try {
    if (Platform.isAndroid) {
      final res = await OpenFilex.open(
        file.path,
        type: 'application/vnd.android.package-archive',
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              res.type == ResultType.done
                  ? '开始安装，若未跳转请在系统弹窗中允许"安装未知应用"'
                  : '无法打开安装包：${res.message}',
            ),
          ),
        );
      }
    } else if (Platform.isWindows) {
      await Process.start(file.path, const [], mode: ProcessStartMode.detached);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('安装器已启动，按提示完成更新')),
        );
      }
    } else {
      if (context.mounted) openExternal(context, release.url);
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法启动安装：$e\n安装包已存至 ${file.path}')),
      );
    }
  }
}

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  PackageInfo? _info;
  var _checking = false;
  var _autoCheck = true;

  @override
  void initState() {
    super.initState();
    _loadInfo();
  }

  Future<void> _loadInfo() async {
    await UpdateSettings.instance.load();
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() {
      _autoCheck = UpdateSettings.instance.autoCheck;
      _info = info;
    });
  }

  String get _version {
    final v = _info?.version ?? '';
    return v.isEmpty ? '…' : 'v$v';
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 检查更新：最新 tag 比本地新则弹窗（说明 + 应用内下载），否则/失败给轻提示
  Future<void> _checkUpdate() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final release = await fetchLatestRelease();
      if (!mounted) return;
      final cur = _info?.version ?? '';
      if (!isNewer(cur, release.tag)) {
        _toast('已是最新版本（${release.tag}）');
        return;
      }
      await showUpdateAvailableDialog(context, release);
    } catch (_) {
      if (mounted) _toast('检查更新失败，请检查网络后重试');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      children: [
        // 头部：校徽 + 应用名 + 版本
        Center(
          child: Column(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.asset(
                  'assets/images/school_badge.png',
                  width: 76,
                  height: 76,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'i泥航',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 2),
              Text(
                _version,
                style: const TextStyle(fontSize: 12.5, color: Colors.black54),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card([
          ListTile(
            leading: const Icon(Icons.system_update_outlined),
            title: const Text('检查更新'),
            subtitle: Text('当前 $_version'),
            trailing: _checking
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right, color: Colors.black26),
            onTap: _checking ? null : _checkUpdate,
          ),
          SwitchListTile(
            title: const Text('自动检查更新'),
            value: _autoCheck,
            onChanged: (v) {
              UpdateSettings.instance.setAutoCheck(v);
              setState(() => _autoCheck = v);
            },
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: const Text('项目仓库'),
            subtitle: const Text('github.com/$repoSlug'),
            trailing: const Icon(
              Icons.open_in_new,
              size: 18,
              color: Colors.black26,
            ),
            onTap: () => openExternal(context, 'https://github.com/$repoSlug'),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('开源许可'),
            subtitle: const Text('MIT License · 查看全部依赖许可'),
            trailing: const Icon(Icons.chevron_right, color: Colors.black26),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const LicensePage(applicationName: 'i泥航'),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        _sectionTitle('数据来源'),
        _card([
          const ListTile(
            leading: Icon(Icons.school_outlined),
            title: Text('aao-eas.nuaa.edu.cn'),
            subtitle: Text('教务系统（金智 EAMS）：课表 / 选课 / 成绩 / 考试'),
            dense: true,
          ),
          const ListTile(
            leading: Icon(Icons.credit_card_outlined),
            title: Text('onecardshall.nuaa.edu.cn'),
            subtitle: Text('新中新一卡通：付款码 / 充值'),
            dense: true,
          ),
          const ListTile(
            leading: Icon(Icons.vpn_key_outlined),
            title: Text('authserver.nuaa.edu.cn'),
            subtitle: Text('CAS 统一身份认证：单点登录'),
            dense: true,
          ),
        ]),
        const SizedBox(height: 12),
        _sectionTitle('说明'),
        _card([
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Text(
              '本应用仅供学习研究与个人效率使用，与南京航空航天大学、'
              '新中新集团、金智教育等任何官方机构无关。使用本项目产生的'
              '一切后果由使用者自行承担，请遵守学校相关规定，'
              '不要高频请求学校服务器。\n\n'
              '⚠ 选课功能未经完整测试，实际选课操作存在不可逆风险'
              '（错选、漏选、并发冲突），使用前请务必在可信环境下'
              '自行确认，后果自负。',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: Colors.black54,
              ),
            ),
          ),
        ]),
      ],
    );
  }

  Widget _sectionTitle(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 0, 6),
    child: Text(
      t,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
    ),
  );

  Widget _card(List<Widget> children) => Card(
    margin: EdgeInsets.zero,
    elevation: 0,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: const BorderSide(color: Colors.black12),
    ),
    child: Column(children: children),
  );
}
