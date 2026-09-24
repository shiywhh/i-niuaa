// Engine | Flutter 3.x / Dart 3 | lib/core/timetable_ics.dart
// 课表导出 .ics：格式对齐 WakeUp课程表 的日历导出（可用日历 App 直接订阅导入）
//   - 每门课按"连续周次段"拆 VEVENT：weeks 6-16,18 → 两个事件，
//     段内 RRULE:FREQ=WEEKLY;UNTIL=<段末周一+7天 的 00:00 CST 转 UTC>，
//     即 UNTIL 日期 = 第1周周一 + (末周-1)*7+6 天、时刻固定 160000Z
//   - DTSTART/DTEND 用节次时间（PeriodTimesStore）换算成当天时刻
//   - LOCATION "教室 老师"；DESCRIPTION "第X - Y节\n教室\n老师"（字面 \n）
//   - VALARM 开课前 20 分钟提醒；CRLF 行尾
// 课表页每次装载数据后把快照写进 [TimetableSnapshot]，
// HomeShell 的分享入口从这里取（不依赖课表页的 state）。

import 'dart:math';

import '../core/models.dart';
import 'period_times.dart';

/// 课表页最近一次装载的快照（学期名 / 时段 / 第 1 周周一锚点）
class TimetableSnapshot {
  static String semesterName = '当前学期';
  static List<CourseSpan> spans = const [];
  static DateTime? firstMonday; // 学期第 1 周的周一；null = 还没锚点
}

/// 文件系统里的非法字符换成下划线（学期名做文件名用）
String sanitizeFileName(String name) =>
    name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();

/// unit（0 起，4/5 为午休）→ 节号（1..11）；午休无节号返回 null
int? unitToPeriod(int unit) {
  if (unit <= 3) return unit + 1;
  if (unit >= 6) return unit - 1;
  return null;
}

String _two(int v) => v.toString().padLeft(2, '0');

String _fmtDate(DateTime d) =>
    '${d.year}${_two(d.month)}${_two(d.day)}';

String _fmtTimeOfDay(int minutes) =>
    '${_two(minutes ~/ 60)}${_two(minutes % 60)}00';

String _fmtUtc(DateTime utc) =>
    '${_fmtDate(utc)}T${_two(utc.hour)}${_two(utc.minute)}${_two(utc.second)}Z';

/// uuid v4（UID 用），Random.secure 随机源
String uuidV4() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final hex = [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// 周次集合 → 连续段 [[a..b], ...]；空集合视为全学期 1..20
List<List<int>> splitWeekRuns(Set<int> weeks) {
  final sorted = (weeks.isEmpty ? {for (var i = 1; i <= 20; i++) i} : weeks)
      .toList()
    ..sort();
  final runs = <List<int>>[];
  var start = sorted.first;
  var prev = start;
  for (final w in sorted.skip(1)) {
    if (w == prev + 1) {
      prev = w;
      continue;
    }
    runs.add([start, prev]);
    start = w;
    prev = w;
  }
  runs.add([start, prev]);
  return runs;
}

/// 生成整学期的 VCALENDAR 文本（CRLF 行尾）
String buildIcs({
  required String semesterName,
  required List<CourseSpan> spans,
  required DateTime firstMonday,
  required List<PeriodTime> periodTimes,
  DateTime? now,
}) {
  final stamp = _fmtUtc((now ?? DateTime.now()).toUtc());
  final lines = <String>[
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//shiywhh//i-niuaa//EN',
    'BEGIN:VTIMEZONE',
    'TZID:Asia/Shanghai',
    'LAST-MODIFIED:$stamp',
    'TZURL:https://www.tzurl.org/zoneinfo-outlook/Asia/Shanghai',
    'X-LIC-LOCATION:Asia/Shanghai',
    'BEGIN:STANDARD',
    'TZNAME:CST',
    'TZOFFSETFROM:+0800',
    'TZOFFSETTO:+0800',
    'DTSTART:19700101T000000',
    'END:STANDARD',
    'END:VTIMEZONE',
  ];

  for (final span in spans) {
    final startPeriod = unitToPeriod(span.startUnit);
    final endPeriod = unitToPeriod(span.endUnit);
    if (startPeriod == null ||
        endPeriod == null ||
        endPeriod < startPeriod ||
        startPeriod > periodTimes.length) {
      continue; // 午休格等无节号的数据不导出
    }
    final startTime = periodTimes[startPeriod - 1].startMinutes;
    final endTime = periodTimes[endPeriod - 1].endMinutes;
    if (endTime <= startTime) continue; // 时间表非法的行不导出
    final location = [span.room, span.teacher]
        .where((s) => s.isNotEmpty)
        .join(' ');
    final desc = '第$startPeriod - $endPeriod节'
        '\\n${span.room}\\n${span.teacher}';

    for (final run in splitWeekRuns(span.weekSet)) {
      final firstDay = firstMonday.add(
        Duration(days: (run[0] - 1) * 7 + span.weekday - 1),
      );
      // UNTIL = 段末周次次周周一的 00:00 CST → 前一天 16:00Z（WakeUp 同口径）
      final untilDate = firstMonday.add(
        Duration(days: (run[1] - 1) * 7 + 6),
      );
      lines
        ..add('BEGIN:VEVENT')
        ..add('DTSTAMP:$stamp')
        ..add('UID:i-niuaa-${uuidV4()}')
        ..add('SUMMARY:${span.name}')
        ..add(
          'DTSTART;TZID=Asia/Shanghai:'
          '${_fmtDate(firstDay)}T${_fmtTimeOfDay(startTime)}',
        )
        ..add(
          'DTEND;TZID=Asia/Shanghai:'
          '${_fmtDate(firstDay)}T${_fmtTimeOfDay(endTime)}',
        )
        ..add(
          'RRULE:FREQ=WEEKLY;UNTIL=${_fmtDate(untilDate)}T160000Z;INTERVAL=1',
        )
        ..add('LOCATION:$location')
        ..add('DESCRIPTION:$desc')
        ..add('BEGIN:VALARM')
        ..add('ACTION:DISPLAY')
        ..add('TRIGGER;RELATED=START:-PT20M')
        ..add('DESCRIPTION:${span.name}@${span.room}\\n')
        ..add('END:VALARM')
        ..add('END:VEVENT');
    }
  }

  lines.add('END:VCALENDAR');
  return lines.join('\r\n');
}
