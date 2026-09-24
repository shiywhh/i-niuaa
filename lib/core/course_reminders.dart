// Engine | Flutter 3.x / Dart 3 | lib/core/course_reminders.dart
// 上课提醒：纯规划器 + 本地通知排程（口径比 Sked 简一个量级——
// 课表 = 学期锚点 + 周次 + 节次时间，全本地可算，一次排满整学期，
// 无需后台补排/贪睡按钮）。
//   - 计划：每门课每周次的"开始节次 - 提前量"各排一条，过去时刻剔除，
//     上限 450 条（Android AlarmManager 实际上限约 500，留余量）
//   - 重排触发：开关/档位变更、课表数据刷新（指纹比对，数据没变不重排）、
//     节次时间变更（监听 PeriodTimesStore.revision）
//   - 仅 Android：Windows 无 flutter_local_notifications 实现，入口直接隐藏
// Deps: flutter_local_notifications, flutter_timezone, timezone, shared_preferences

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'models.dart';
import 'period_times.dart';
import 'timetable_ics.dart' show TimetableSnapshot, unitToPeriod;

/// 单条提醒目标（纯数据，可单测）
class ReminderPlanItem {
  final int id; // 通知 id（正 int32，同 id 覆盖）
  final String title;
  final String body;
  final DateTime fireAt; // 本地时刻

  const ReminderPlanItem(this.id, this.title, this.body, this.fireAt);
}

/// 规划结果：items 可能被截断到 [maxItems]，overflow 标记是否发生
class ReminderPlan {
  final List<ReminderPlanItem> items;
  final bool overflow;
  const ReminderPlan(this.items, this.overflow);
}

/// 从课表快照构建整学期的提醒计划（纯函数）。
/// 周次集合为空视为全学期 1..20（与 ics 导出同口径）
ReminderPlan buildReminderPlan({
  required List<CourseSpan> spans,
  required DateTime firstMonday,
  required List<PeriodTime> periodTimes,
  required int leadMinutes,
  required DateTime now,
  int maxItems = 450,
}) {
  final items = <ReminderPlanItem>[];
  var overflow = false;
  for (final span in spans) {
    final period = unitToPeriod(span.startUnit);
    if (period == null || period > periodTimes.length) continue;
    final start = periodTimes[period - 1].startMinutes;
    final fire = start - leadMinutes;
    final hour = fire ~/ 60;
    final minute = fire % 60;
    if (fire < 0) continue; // 提前量跨过午夜的不支持（作息不会这样排）

    final segments = [
      '第$period节 ${formatMinutes(start)}',
      if (span.room.isNotEmpty) span.room,
      if (span.teacher.isNotEmpty) span.teacher,
    ];
    final bodyPrefix = segments.join(' · ');

    final weeks = span.weekSet.isEmpty
        ? [for (var w = 1; w <= 20; w++) w]
        : span.weekSet.toList()..sort();
    for (final w in weeks) {
      final day = firstMonday.add(
        Duration(days: (w - 1) * 7 + span.weekday - 1, hours: hour, minutes: minute),
      );
      if (!day.isAfter(now)) continue;
      if (items.length >= maxItems) {
        overflow = true;
        break;
      }
      final id =
          Object.hash(span.name, span.weekday, w, span.startUnit) & 0x7fffffff;
      items.add(
        ReminderPlanItem(id, span.name, '$bodyPrefix · 第$w周', day),
      );
    }
    if (overflow) break;
  }
  return ReminderPlan(items, overflow);
}

/// 开关 + 档位的存取与排程执行
class CourseReminders {
  CourseReminders._();
  static final instance = CourseReminders._();

  static const _enabledKey = 'reminder_enabled_v1';
  static const _leadKey = 'reminder_lead_v1';
  static const _fingerprintKey = 'reminder_fingerprint_v1';

  /// 数据/设置变化通知（设置页刷新状态用）
  final ValueNotifier<int> revision = ValueNotifier(0);

  var _enabled = false;
  var _leadMinutes = 10;
  var _tzReady = false;

  bool get enabled => _enabled;
  int get leadMinutes => _leadMinutes;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _enabled = p.getBool(_enabledKey) ?? false;
      _leadMinutes = p.getInt(_leadKey) ?? 10;
      if (!const [10, 20, 30].contains(_leadMinutes)) _leadMinutes = 10;
    } catch (_) {}
    revision.value++;
  }

  /// 开关：开 = 排程，关 = 取消全部
  Future<String?> setEnabled(bool value) async {
    _enabled = value;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_enabledKey, value);
      await p.remove(_fingerprintKey);
    } catch (_) {}
    String? err;
    if (value) {
      err = await reschedule(reason: 'enable');
    } else {
      await _cancelAll();
    }
    revision.value++;
    return err;
  }

  /// 换档位：持久化后重排
  Future<String?> setLeadMinutes(int minutes) async {
    _leadMinutes = minutes;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_leadKey, minutes);
      await p.remove(_fingerprintKey);
    } catch (_) {}
    final err = _enabled ? await reschedule(reason: 'lead') : null;
    revision.value++;
    return err;
  }

  /// 课表数据/节次时间变化后调用：指纹没变直接跳过，避免反复清空重排
  Future<void> refreshIfDataChanged() async {
    if (!_enabled) return;
    final fp = _fingerprint();
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getString(_fingerprintKey) == fp) return;
      await p.setString(_fingerprintKey, fp);
    } catch (_) {}
    await reschedule(reason: 'data');
  }

  String _fingerprint() =>
      '$leadMinutes|${TimetableSnapshot.firstMonday?.toIso8601String()}|'
      '${TimetableSnapshot.spans.map((s) => s.toJson()).join()}|'
      '${PeriodTimesStore.instance.times.map((t) => t.toJson()).join()}';

  /// 当前指纹对应的通知条数（设置页展示用）
  int planCount() => buildReminderPlan(
    spans: TimetableSnapshot.spans,
    firstMonday: TimetableSnapshot.firstMonday!,
    periodTimes: PeriodTimesStore.instance.times,
    leadMinutes: _leadMinutes,
    now: DateTime.now(),
  ).items.length;

  Future<void> _cancelAll() async {
    if (!Platform.isAndroid) return;
    try {
      await _plugin().cancelAll();
    } catch (_) {}
  }

  FlutterLocalNotificationsPlugin _plugin() => FlutterLocalNotificationsPlugin();

  /// 全量重排。返回错误文案（null = 成功，含排了多少条的提示由调用方拼）
  Future<String?> reschedule({required String reason}) async {
    if (!Platform.isAndroid) return '提醒仅支持 Android';
    final monday = TimetableSnapshot.firstMonday;
    if (TimetableSnapshot.spans.isEmpty || monday == null) {
      return '课表还没加载好，先回课表页刷新一次';
    }
    try {
      await _ensureTzAndInit();
      final android =
          _plugin().resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      // Android 13+ 通知权限；12+ 精确闹钟权限（拒绝则降级 inexact）
      await android?.requestNotificationsPermission();
      var exact = true;
      final granted = await android?.requestExactAlarmsPermission();
      if (granted == false) exact = false;

      await android?.cancelAll();
      final plan = buildReminderPlan(
        spans: TimetableSnapshot.spans,
        firstMonday: monday,
        periodTimes: PeriodTimesStore.instance.times,
        leadMinutes: _leadMinutes,
        now: DateTime.now(),
      );
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'course_reminder',
          '上课提醒',
          channelDescription: '按节次时间提前提醒即将开始的课程',
          importance: Importance.high,
          priority: Priority.high,
          styleInformation: BigTextStyleInformation(''),
        ),
      );
      for (final item in plan.items) {
        await _plugin().zonedSchedule(
          id: item.id,
          title: item.title,
          body: item.body,
          scheduledDate: tz.TZDateTime.from(item.fireAt, tz.local),
          notificationDetails: details,
          androidScheduleMode: exact
              ? AndroidScheduleMode.exactAllowWhileIdle
              : AndroidScheduleMode.inexactAllowWhileIdle,
        );
      }
      debugPrint(
        'reminders rescheduled ($reason): ${plan.items.length} items, '
        'exact=$exact, overflow=${plan.overflow}',
      );
      _pendingCount = plan.items.length;
      _exact = exact;
      _overflow = plan.overflow;
      return null;
    } catch (e) {
      return '排程失败：$e';
    }
  }

  var _pendingCount = 0;
  var _exact = true;
  var _overflow = false;
  int get pendingCount => _pendingCount;
  bool get exact => _exact;
  bool get overflow => _overflow;

  Future<void> _ensureTzAndInit() async {
    if (!_tzReady) {
      tz_data.initializeTimeZones();
      try {
        final tzInfo = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(tzInfo.identifier));
      } catch (_) {
        tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
      }
      await _plugin().initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      _tzReady = true;
    }
  }
}
