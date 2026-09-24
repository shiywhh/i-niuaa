// Engine | Flutter 3.x / Dart 3 | lib/ui/period_times_page.dart
// 课表设置（原节次时间设置，编辑器交互抄自 Sked 的 period_times_page）：
//   - 固定 11 节，与课表时间栏一致，只改时刻不增删节
//   - 顶部切换将军路/明故宫/天目湖三校区作息预设（三四节错峰口径已钉死）
//   - 显示设置：周六/周日列、非本周课、课卡内容与对齐、行高、
//     列宽模式、时间栏时刻（改动即时生效）
//   - 每行显示时长 / 距上一节间隔；结束 <= 开始、与上一节重叠标红，
//     有非法行时不落盘（Sked 同策略），改合法后自动写入
// Deps: shared_preferences

import 'package:flutter/material.dart';

import '../core/period_times.dart';
import '../core/timetable_settings.dart';

class PeriodTimesPage extends StatefulWidget {
  const PeriodTimesPage({super.key});

  @override
  State<PeriodTimesPage> createState() => _PeriodTimesPageState();
}

class _PeriodTimesPageState extends State<PeriodTimesPage> {
  List<PeriodTime> _times = const [];
  var _loading = true;
  var _pickerOpen = false;
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
    await PeriodTimesStore.instance.ensureLoaded();
    await TimetableSettings.instance.load();
    if (!mounted) return;
    setState(() {
      _times = List.of(PeriodTimesStore.instance.times);
      _rowHeightCtrl.text = TimetableSettings.instance.rowHeight
          .toStringAsFixed(0);
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

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('课表设置')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final s = TimetableSettings.instance;
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
          _sectionTitle('节次时间'),
          // 校区作息预设切换（手动改时刻不切档，仅覆盖时间值）
          SegmentedButton<String>(
            segments: [
              for (final c in campusNames)
                ButtonSegment(value: c, label: Text(c)),
            ],
            selected: {PeriodTimesStore.instance.campus},
            onSelectionChanged: (sel) => _selectCampus(sel.first),
          ),
          const SizedBox(height: 8),
          ...[for (var i = 0; i < _times.length; i++) _periodRow(i)],
          const SizedBox(height: 16),
          _sectionTitle('显示'),
          _settingsCard([
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
          _settingsCard([
            SwitchListTile(
              title: const Text('课卡显示教室'),
              value: s.cardShowRoom,
              onChanged: (v) {
                s.setCardShowRoom(v);
                setState(() {});
              },
            ),
            SwitchListTile(
              title: const Text('课卡显示老师'),
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
              title: const Text('课卡文字水平居中'),
              value: s.cardCenterH,
              onChanged: (v) {
                s.setCardCenterH(v);
                setState(() {});
              },
            ),
            SwitchListTile(
              title: const Text('课卡文字垂直居中'),
              value: s.cardCenterV,
              onChanged: (v) {
                s.setCardCenterV(v);
                setState(() {});
              },
            ),
          ]),
          const SizedBox(height: 12),
          _settingsCard([
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

  void _applyRowHeight(String v) {
    final h = double.tryParse(v);
    if (h == null) return;
    TimetableSettings.instance.setRowHeight(h);
    setState(() {
      _rowHeightCtrl.text = TimetableSettings.instance.rowHeight
          .toStringAsFixed(0);
    });
  }

  Widget _sectionTitle(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 0, 6),
    child: Text(
      t,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
    ),
  );

  Widget _settingsCard(List<Widget> children) => Card(
    margin: EdgeInsets.zero,
    elevation: 0,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: const BorderSide(color: Colors.black12),
    ),
    child: Column(children: children),
  );

  Widget _periodRow(int i) {
    final period = _times[i];
    final duration = period.endMinutes - period.startMinutes;
    final gap = i == 0 ? null : period.startMinutes - _times[i - 1].endMinutes;
    final invalid =
        duration <= 0 ||
        (gap != null && gap < 0) ||
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
