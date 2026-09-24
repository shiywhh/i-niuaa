// Engine | Flutter 3.x / Dart 3 | lib/ui/home_shell.dart
// 底部六栏壳：课表 / 选课 / 成绩 / 考试 / 校园卡 / 关于，右上角分享与退出登录

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/period_times.dart';
import '../core/session.dart';
import '../core/timetable_ics.dart';
import 'about_page.dart';
import 'campus_card_page.dart';
import 'election_page.dart';
import 'exams_page.dart';
import 'grades_page.dart';
import 'login_page.dart';
import 'period_times_page.dart';
import 'timetable_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  // 课表页顶部两行的收起状态：AppBar 按钮写入，课表页监听
  final ValueNotifier<bool> _ttCollapsed = ValueNotifier(false);
  late final _pages = [
    TimetablePage(collapsed: _ttCollapsed),
    const ElectionsPage(),
    const GradesPage(),
    const ExamsPage(),
    const CampusCardPage(),
    const AboutPage(),
  ];

  @override
  void dispose() {
    _ttCollapsed.dispose();
    super.dispose();
  }

  // ---------- 课表导出 / 分享 ----------

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 组 ICS 文本；数据未就绪时提示并返回 null
  String? _buildIcs() {
    final spans = TimetableSnapshot.spans;
    final monday = TimetableSnapshot.firstMonday;
    if (spans.isEmpty) {
      _toast('课表还没加载好，稍后再试');
      return null;
    }
    if (monday == null) {
      _toast('还没有学期锚点：先在课表页刷新出当前教学周');
      return null;
    }
    return buildIcs(
      semesterName: TimetableSnapshot.semesterName,
      spans: spans,
      firstMonday: monday,
      periodTimes: PeriodTimesStore.instance.times,
    );
  }

  String get _icsFileName =>
      '${sanitizeFileName(TimetableSnapshot.semesterName)}.ics';

  /// 导出为日历文件：系统保存对话框，写到用户选的位置
  Future<void> _exportIcs() async {
    final ics = _buildIcs();
    if (ics == null) return;
    try {
      final location = await getSaveLocation(
        suggestedName: _icsFileName,
      );
      if (location == null) return; // 用户取消
      await File(location.path).writeAsString(ics);
      _toast('已导出：${location.path}');
    } on UnsupportedError {
      _toast('此平台不支持导出，请改用「分享」');
    } catch (e) {
      _toast('导出失败：$e');
    }
  }

  /// 分享：写临时文件后唤起系统分享（Android 分享面板 / 桌面共享 UI）
  Future<void> _shareIcs() async {
    final ics = _buildIcs();
    if (ics == null) return;
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$_icsFileName');
      await file.writeAsString(ics);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/calendar')],
          text: TimetableSnapshot.semesterName,
        ),
      );
    } catch (e) {
      _toast('分享失败：$e');
    }
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定退出当前账号？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await Session.I.logout();
      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const LoginPage()),
          (_) => false,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('i泥航'),
        actions: [
          // 展开/收起课表页顶部两行：只在课表 tab 出现，位于退出登录左侧
          // 节次时间设置：只在课表 tab 出现，位于收起按钮左侧
          if (_tab == 0)
            IconButton(
              tooltip: '节次时间设置',
              icon: const Icon(Icons.schedule_outlined),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PeriodTimesPage()),
              ),
            ),
          // 课表导出/分享：只在课表 tab 出现，位于节次时间与收起之间
          if (_tab == 0)
            PopupMenuButton<String>(
              tooltip: '导出/分享课表',
              icon: const Icon(Icons.ios_share),
              onSelected: (v) =>
                  v == 'ics' ? _exportIcs() : _shareIcs(),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'ics',
                  child: Text('导出为日历文件'),
                ),
                PopupMenuItem(value: 'share', child: Text('分享')),
              ],
            ),
          if (_tab == 0)
            ValueListenableBuilder<bool>(
              valueListenable: _ttCollapsed,
              builder: (ctx, collapsed, child) => IconButton(
                tooltip: collapsed ? '展开筛选栏' : '收起筛选栏',
                icon: Icon(collapsed ? Icons.expand_more : Icons.expand_less),
                onPressed: () => _ttCollapsed.value = !collapsed,
              ),
            ),
          IconButton(
            tooltip: '退出登录',
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
      ),
      body: IndexedStack(index: _tab, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: '课表',
          ),
          NavigationDestination(
            icon: Icon(Icons.how_to_reg_outlined),
            selectedIcon: Icon(Icons.how_to_reg),
            label: '选课',
          ),
          NavigationDestination(
            icon: Icon(Icons.grade_outlined),
            selectedIcon: Icon(Icons.grade),
            label: '成绩',
          ),
          NavigationDestination(
            icon: Icon(Icons.event_outlined),
            selectedIcon: Icon(Icons.event),
            label: '考试',
          ),
          NavigationDestination(
            icon: Icon(Icons.badge_outlined),
            selectedIcon: Icon(Icons.badge),
            label: '校园卡',
          ),
          NavigationDestination(
            icon: Icon(Icons.info_outline),
            selectedIcon: Icon(Icons.info),
            label: '关于',
          ),
        ],
      ),
    );
  }
}
