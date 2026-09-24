// Engine | Flutter 3.x / Dart 3 | lib/ui/period_times_page.dart
// 课表设置（原节次时间设置，编辑器交互抄自 Sked 的 period_times_page）：
//   - 固定 11 节，与课表时间栏一致，只改时刻不增删节
//   - 顶部切换将军路/明故宫/天目湖三校区作息预设（三四节错峰口径已钉死）
//   - 上课提醒（仅 Android）：开关 + 提前 10/20/30 分钟档位，
//     排程覆盖整学期，课表/作息数据变化自动重排
//   - 每行显示时长 / 距上一节间隔；结束 <= 开始、与上一节重叠标红，
//     有非法行时不落盘（Sked 同策略），改合法后自动写入
// Deps: shared_preferences, flutter_local_notifications

import 'dart:io';

import 'package:flutter/material.dart';

import '../core/course_reminders.dart';
import '../core/period_times.dart';

class PeriodTimesPage extends StatefulWidget {
  const PeriodTimesPage({super.key});

  @override
  State<PeriodTimesPage> createState() => _PeriodTimesPageState();
}

class _PeriodTimesPageState extends State<PeriodTimesPage> {
  List<PeriodTime> _times = const [];
  var _loading = true;
  var _pickerOpen = false;
  var _reminderOn = false;
  var _reminderBusy = false;
  var _reminderLead = 10;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await PeriodTimesStore.instance.ensureLoaded();
    await CourseReminders.instance.load();
    if (!mounted) return;
    setState(() {
      _times = List.of(PeriodTimesStore.instance.times);
      _reminderOn = CourseReminders.instance.enabled;
      _reminderLead = CourseReminders.instance.leadMinutes;
      _loading = false;
    });
  }

  /// 改一行时刻：非法不落盘（时间栏维持最近一次合法值），合法即写
  Future<void> _pick(int index, {required bool isStart}) async {
    if (_pickerOpen) return;
    final period = _times[index];
    final minutes = isStart ? period.startMinutes : period.endMinutes;
    setState(() => _pickerOpen = true);
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (mounted) setState(() => _pickerOpen = false);
    if (picked == null || !mounted) return;
    final value = picked.hour * 60 + picked.minute;
    final next = List.of(_times);
    next[index] = isStart
        ? next[index].copyWith(startMinutes: value)
        : next[index].copyWith(endMinutes: value);
    setState(() => _times = next);
    if (!hasInvalidPeriodTimes(next)) {
      await PeriodTimesStore.instance.save(next);
    }
  }

  /// 切校区：应用该校区预设作息
  Future<void> _selectCampus(String name) async {
    if (name == PeriodTimesStore.instance.campus) return;
    await PeriodTimesStore.instance.selectCampus(name);
    if (!mounted) return;
    setState(() => _times = List.of(PeriodTimesStore.instance.times));
  }

  Future<void> _resetDefault() async {
    final campus = PeriodTimesStore.instance.campus;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('恢复$campus作息'),
        content: const Text('将覆盖当前全部 11 节的时间，确定？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final defaults = campusPreset(campus);
    setState(() => _times = defaults);
    await PeriodTimesStore.instance.save(defaults);
  }

  // ---------- 上课提醒 ----------

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _toggleReminder(bool value) async {
    if (_reminderBusy) return;
    setState(() => _reminderBusy = true);
    final err = await CourseReminders.instance.setEnabled(value);
    if (!mounted) return;
    setState(() {
      _reminderBusy = false;
      if (err == null) _reminderOn = value;
    });
    if (err != null) {
      _toast(err);
      return;
    }
    if (!value) {
      _toast('已取消全部上课提醒');
      return;
    }
    final n = CourseReminders.instance.pendingCount;
    _toast(
      n == 0
          ? '已开启，等课表加载后自动排程'
          : '已排 $n 条上课提醒${CourseReminders.instance.exact ? '' : '（精确闹钟未授权，时间可能有几分钟误差）'}',
    );
  }

  Future<void> _setLead(int minutes) async {
    if (_reminderBusy) return;
    setState(() => _reminderBusy = true);
    final err = await CourseReminders.instance.setLeadMinutes(minutes);
    if (!mounted) return;
    setState(() {
      _reminderBusy = false;
      if (err == null) _reminderLead = minutes;
    });
    _toast(err ?? '已按提前 $minutes 分钟重排 ${CourseReminders.instance.pendingCount} 条提醒');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('课表设置')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final showReminder = Platform.isAndroid;
    return Scaffold(
      appBar: AppBar(
        title: const Text('课表设置'),
        actions: [
          IconButton(
            tooltip: '恢复默认',
            icon: const Icon(Icons.restart_alt),
            onPressed: _pickerOpen ? null : _resetDefault,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          // 校区作息预设切换（手动改时刻不切档，仅覆盖时间值）
          SegmentedButton<String>(
            segments: [
              for (final c in campusNames)
                ButtonSegment(value: c, label: Text(c)),
            ],
            selected: {PeriodTimesStore.instance.campus},
            onSelectionChanged: (sel) => _selectCampus(sel.first),
          ),
          // 上课提醒（仅 Android；Windows 无本地通知实现）
          if (showReminder) ...[
            const SizedBox(height: 12),
            Card(
              margin: EdgeInsets.zero,
              elevation: 0,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: const BorderSide(color: Colors.black12),
              ),
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text(
                      '上课提醒',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      _reminderOn
                          ? '开课前 $_reminderLead 分钟通知（含教室/老师/周次）'
                          : '整学期课程开课前提醒你',
                    ),
                    value: _reminderOn,
                    onChanged: _reminderBusy ? null : _toggleReminder,
                  ),
                  if (_reminderOn)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(value: 10, label: Text('提前10分')),
                          ButtonSegment(value: 20, label: Text('提前20分')),
                          ButtonSegment(value: 30, label: Text('提前30分')),
                        ],
                        selected: {_reminderLead},
                        onSelectionChanged: (sel) => _setLead(sel.first),
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          _sectionTitle('节次时间'),
          ...[for (var i = 0; i < _times.length; i++) _periodRow(i)],
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

  Widget _periodRow(int i) {
    final period = _times[i];
    final duration = period.endMinutes - period.startMinutes;
    final gap = i == 0 ? null : period.startMinutes - _times[i - 1].endMinutes;
    final invalid =
        duration <= 0 || (gap != null && gap < 0) ||
        (i > 0 && period.startMinutes < _times[i - 1].endMinutes);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.black12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              SizedBox(
                width: 40,
                child: Text(
                  '第${period.index}节',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: _TimeField(
                        label: '上课',
                        value: formatMinutes(period.startMinutes),
                        enabled: !_pickerOpen,
                        onTap: () => _pick(i, isStart: true),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4),
                      child: Text('–', style: TextStyle(color: Colors.black38)),
                    ),
                    Expanded(
                      child: _TimeField(
                        label: '下课',
                        value: formatMinutes(period.endMinutes),
                        enabled: !_pickerOpen,
                        onTap: () => _pick(i, isStart: false),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 92,
                child: Text(
                  invalid
                      ? (duration <= 0 ? '结束需晚于开始' : '与上一节重叠')
                      : [
                          '时长 $duration 分钟',
                          if (gap != null) '间隔 $gap 分钟',
                        ].join('\n'),
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.3,
                    color: invalid ? const Color(0xFFB3261E) : Colors.black45,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 上课/下课时刻按钮：上标签下时刻，点击弹 24 小时制时间选择器
class _TimeField extends StatelessWidget {
  const _TimeField({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final String value;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.black26),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 10, color: Colors.black45),
            ),
            Text(
              value,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
