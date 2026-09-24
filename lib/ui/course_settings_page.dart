// Engine | Flutter 3.x / Dart 3 | lib/ui/course_settings_page.dart
// 课表设置页：显示设置（列/内容/对齐/行高/列宽模式/时间栏时刻）
// + 节次时间入口（跳独立编辑页：三校区预设 + 每节上下课时刻）。
// 所有开关即时生效（课表页监听 TimetableSettings.revision）。
// Deps: shared_preferences

import 'package:flutter/material.dart';

import '../core/timetable_settings.dart';
import 'period_times_page.dart';

class CourseSettingsPage extends StatefulWidget {
  const CourseSettingsPage({super.key});

  @override
  State<CourseSettingsPage> createState() => _CourseSettingsPageState();
}

class _CourseSettingsPageState extends State<CourseSettingsPage> {
  final _rowHeightCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _rowHeightCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    await TimetableSettings.instance.load();
    if (!mounted) return;
    setState(() {
      _rowHeightCtrl.text = TimetableSettings.instance.rowHeight
          .toStringAsFixed(0);
    });
  }

  void _applyRowHeight(String v) {
    final h = double.tryParse(v);
    if (h == null) return;
    TimetableSettings.instance.setRowHeight(h);
    setState(() {
      _rowHeightCtrl.text = TimetableSettings.instance.rowHeight
          .toStringAsFixed(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = TimetableSettings.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('课表设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          _card([
            ListTile(
              leading: const Icon(Icons.access_time_outlined),
              title: const Text('节次时间'),
              subtitle: const Text('三校区作息预设 · 每节上下课时刻'),
              trailing: const Icon(Icons.chevron_right, color: Colors.black26),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PeriodTimesPage()),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          _sectionTitle('显示'),
          _card([
            SwitchListTile(
              title: const Text('显示周六'),
              value: s.showSaturday,
              onChanged: (v) {
                s.setShowSaturday(v);
                setState(() {});
              },
            ),
            SwitchListTile(
              title: const Text('显示周日'),
              value: s.showSunday,
              onChanged: (v) {
                s.setShowSunday(v);
                setState(() {});
              },
            ),
            SwitchListTile(
              title: const Text('显示非本周课程'),
              subtitle: const Text('关闭后，选具体周时只显示该周在上的课'),
              value: s.showNonCurrentWeek,
              onChanged: (v) {
                s.setShowNonCurrentWeek(v);
                setState(() {});
              },
            ),
            SwitchListTile(
              title: const Text('时间栏显示时刻'),
              value: s.showRailTimes,
              onChanged: (v) {
                s.setShowRailTimes(v);
                setState(() {});
              },
            ),
          ]),
          const SizedBox(height: 12),
          _sectionTitle('课卡'),
          _card([
            SwitchListTile(
              title: const Text('显示教室'),
              value: s.cardShowRoom,
              onChanged: (v) {
                s.setCardShowRoom(v);
                setState(() {});
              },
            ),
            SwitchListTile(
              title: const Text('显示老师'),
              value: s.cardShowTeacher,
              onChanged: (v) {
                s.setCardShowTeacher(v);
                setState(() {});
              },
            ),
            SwitchListTile(
              title: const Text('全部周视图显示"N周"角标'),
              value: s.cardShowWeeksTag,
              onChanged: (v) {
                s.setCardShowWeeksTag(v);
                setState(() {});
              },
            ),
            SwitchListTile(
              title: const Text('文字水平居中'),
              value: s.cardCenterH,
              onChanged: (v) {
                s.setCardCenterH(v);
                setState(() {});
              },
            ),
            SwitchListTile(
              title: const Text('文字垂直居中'),
              value: s.cardCenterV,
              onChanged: (v) {
                s.setCardCenterV(v);
                setState(() {});
              },
            ),
          ]),
          const SizedBox(height: 12),
          _sectionTitle('布局'),
          _card([
            SwitchListTile(
              title: const Text('列宽塞满屏幕'),
              subtitle: const Text('关闭时保持最小列宽，超出横向滚动'),
              value: s.fitWidth,
              onChanged: (v) {
                s.setFitWidth(v);
                setState(() {});
              },
            ),
            ListTile(
              title: const Text('行高（像素）'),
              subtitle: const Text('默认 80，范围 56 - 128'),
              trailing: SizedBox(
                width: 84,
                child: TextField(
                  controller: _rowHeightCtrl,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (v) => _applyRowHeight(v),
                ),
              ),
            ),
          ]),
        ],
      ),
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
