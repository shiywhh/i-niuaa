// Engine | Flutter 3.x / Dart 3 | test/timetable_ics_test.dart
// 断言口径直接对齐 WakeUp课程表 导出的参考 ics。
// Run: flutter test

import 'package:flutter_test/flutter_test.dart';

import 'package:nuaa_eams/core/models.dart';
import 'package:nuaa_eams/core/period_times.dart';
import 'package:nuaa_eams/core/timetable_ics.dart';

void main() {
  // 学期第 1 周周一：2026-08-31；作息用将军路预设
  final monday = DateTime(2026, 8, 31);
  final times = campusPreset('将军路');

  test('unitToPeriod：午休无节号', () {
    expect(unitToPeriod(0), 1);
    expect(unitToPeriod(3), 4);
    expect(unitToPeriod(4), isNull);
    expect(unitToPeriod(5), isNull);
    expect(unitToPeriod(6), 5);
    expect(unitToPeriod(12), 11);
  });

  test('splitWeekRuns：连续合并、断口拆段、空集视为全学期', () {
    expect(splitWeekRuns({6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18}), [
      [6, 16],
      [18, 18],
    ]);
    expect(splitWeekRuns({}), [
      [1, 20],
    ]);
    expect(splitWeekRuns({5}), [
      [5, 5],
    ]);
  });

  test('sanitizeFileName 替换非法字符', () {
    expect(sanitizeFileName('2026-2027第1学期'), '2026-2027第1学期');
    expect(sanitizeFileName('a/b\\c:d*e?f"g<h>i|j'), 'a_b_c_d_e_f_g_h_i_j');
  });

  test('跨节时段单周次段：事件行与 WakeUp 参考文件同格式', () {
    final span = CourseSpan(
      '线性代数',
      '胡志成',
      '6-16',
      '10107(将军路)',
      1, // 周一
      startUnit: 6,
      endUnit: 7, // 第 5-6 节 14:00-15:45
    );
    final ics = buildIcs(
      semesterName: '2026-2027第1学期',
      spans: [span],
      firstMonday: monday,
      periodTimes: times,
      now: DateTime.utc(2026, 9, 24, 5, 30, 0),
    );

    expect(ics.contains('BEGIN:VCALENDAR'), isTrue);
    expect(ics.contains('VERSION:2.0'), isTrue);
    expect(ics.contains('PRODID:-//shiywhh//i-niuaa//EN'), isTrue);
    expect(ics.contains('TZID:Asia/Shanghai'), isTrue);

    // 第 6 周周一 = 2026-10-05；第 5 节 14:00 起、第 6 节 15:45 止
    expect(
      ics.contains('DTSTART;TZID=Asia/Shanghai:20261005T140000'),
      isTrue,
    );
    expect(
      ics.contains('DTEND;TZID=Asia/Shanghai:20261005T154500'),
      isTrue,
    );
    // 段末 16 周 → UNTIL = 周一(8/31) + 15*7+6 天 = 2026-12-20 的 160000Z
    expect(
      ics.contains('RRULE:FREQ=WEEKLY;UNTIL=20261220T160000Z;INTERVAL=1'),
      isTrue,
    );
    expect(ics.contains('LOCATION:10107(将军路) 胡志成'), isTrue);
    expect(
      ics.contains(r'DESCRIPTION:第5 - 6节\n10107(将军路)\n胡志成'),
      isTrue,
    );
    expect(ics.contains('BEGIN:VALARM'), isTrue);
    expect(ics.contains('TRIGGER;RELATED=START:-PT20M'), isTrue);
    expect(ics.contains('SUMMARY:线性代数'), isTrue);
    expect(RegExp(r'UID:i-niuaa-[0-9a-f-]{36}').hasMatch(ics), isTrue);
    expect(ics.contains('DTSTAMP:20260924T053000Z'), isTrue);
    // CRLF 行尾
    expect(ics.contains('\r\n'), isTrue);
    expect(ics.endsWith('END:VCALENDAR'), isTrue);
  });

  test('断开的周次拆两个事件，UNTIL 各自算', () {
    final span = CourseSpan(
      '数字电路与逻辑设计Ⅱ',
      '徐帆',
      '6-16,18',
      '2203(将军路)',
      1,
      startUnit: 0,
      endUnit: 1, // 第 1-2 节 08:00-09:45
    );
    final ics = buildIcs(
      semesterName: '2026-2027第1学期',
      spans: [span],
      firstMonday: monday,
      periodTimes: times,
    );
    expect(
      ics.contains('DTSTART;TZID=Asia/Shanghai:20261005T080000'),
      isTrue,
    );
    expect(
      ics.contains('DTSTART;TZID=Asia/Shanghai:20261228T080000'),
      isTrue,
    );
    expect(ics.contains('UNTIL=20261220T160000Z'), isTrue);
    // 单周 18：UNTIL = 周一 + 17*7+6 天 = 2027-01-03
    expect(ics.contains('UNTIL=20270103T160000Z'), isTrue);
    expect('END:VEVENT'.allMatches(ics).length, 2);
  });

  test('其他星期：周三课落在本周周三（9/2），午休格跳过', () {
    final wed = CourseSpan(
      '中国文化（英语）',
      '梁红飞',
      '1-16',
      '7302(将军路)',
      3,
      startUnit: 6,
      endUnit: 7,
    );
    final lunch = CourseSpan(
      '不存在的午休课',
      '',
      '1-16',
      '',
      1,
      startUnit: 4,
      endUnit: 5,
    );
    final ics = buildIcs(
      semesterName: '2026-2027第1学期',
      spans: [wed, lunch],
      firstMonday: monday,
      periodTimes: times,
    );
    expect(
      ics.contains('DTSTART;TZID=Asia/Shanghai:20260902T140000'),
      isTrue,
    );
    expect(ics.contains('不存在的午休课'), isFalse);
    expect('BEGIN:VEVENT'.allMatches(ics).length, 1);
  });

  test('结束时间非法的行不导出', () {
    final bad = CourseSpan('坏数据', '', '1', '', 1, startUnit: 0, endUnit: 1);
    final ics = buildIcs(
      semesterName: 'x',
      spans: [bad],
      firstMonday: monday,
      periodTimes: [for (final t in times) t.copyWith(endMinutes: 0)],
    );
    expect(ics.contains('BEGIN:VEVENT'), isFalse);
  });
}
