// Engine | Flutter 3.x / Dart 3 | lib/ui/home_shell.dart
// 底部三栏壳：课表 / 成绩 / 考试，右上角退出登录

import 'package:flutter/material.dart';

import '../core/session.dart';
import 'campus_card_page.dart';
import 'election_page.dart';
import 'exams_page.dart';
import 'grades_page.dart';
import 'login_page.dart';
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
  ];

  @override
  void dispose() {
    _ttCollapsed.dispose();
    super.dispose();
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
        ],
      ),
    );
  }
}
