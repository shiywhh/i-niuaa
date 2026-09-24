// Engine | Flutter 3.x / Dart 3 | test/course_reminders_test.dart
// Run: flutter test

import 'package:flutter_test/flutter_test.dart';

import 'package:nuaa_eams/core/course_reminders.dart';
import 'package:nuaa_eams/core/models.dart';
import 'package:nuaa_eams/core/period_times.dart';

void main() {
  final monday = DateTime(2026, 8, 31); // 学期第 1 周周一
  final times = campusPreset('将军路');
  final now = DateTime(2026, 9, 24, 12, 0); // 第 4 周（9/21-9/27）周四中午

  CourseSpan span(
    String name,
    int weekday,
    int startUnit,
    int endUnit,
    String weeks, {
    String room = '2203(将军路)',
    String teacher = '徐帆',
  }) => CourseSpan(name, teacher, weeks, room, weekday,
      startUnit: startUnit, endUnit: endUnit);

  test('基本排程：提前量、内容、周次数', () {
    final plan = buildReminderPlan(
      spans: [span('数字电路与逻辑设计Ⅱ', 1, 0, 1, '6-16')],
      firstMonday: monday,
      periodTimes: times,
      leadMinutes: 10,
      now: now,
    );
    // 第 6-16 周，第 4 周的已过滤（6 周起）
    expect(plan.items.length, 11);
    expect(plan.overflow, isFalse);

    // 第 6 周周一 10/5，第 1 节 08:00 提前 10 分钟 -> 07:50
    final first = plan.items.first;
    expect(first.fireAt, DateTime(2026, 10, 5, 7, 50));
    expect(first.title, '数字电路与逻辑设计Ⅱ');
    expect(
      first.body,
      '第1节 08:00 · 2203(将军路) · 徐帆 · 第6周',
    );
    // 最后一条 = 第 16 周 12/14
    expect(plan.items.last.fireAt, DateTime(2026, 12, 14, 7, 50));
    expect(plan.items.last.body.endsWith('第16周'), isTrue);
    // id 稳定且为正
    expect(
      plan.items.every((i) => i.id > 0 && i.id <= 0x7fffffff),
      isTrue,
    );
  });

  test('提前 30 分钟档位与不同星期', () {
    final plan = buildReminderPlan(
      spans: [span('中国文化（英语）', 3, 6, 7, '1-16', room: '7302(将军路)', teacher: '梁红飞')],
      firstMonday: monday,
      periodTimes: times,
      leadMinutes: 30,
      now: DateTime(2026, 8, 1), // 学期前，全部保留
    );
    // 第 5 节 14:00 提前 30 分钟 -> 13:30；周一+2 天 = 周三
    expect(plan.items.first.fireAt, DateTime(2026, 9, 2, 13, 30));
    expect(
      plan.items.first.body,
      '第5节 14:00 · 7302(将军路) · 梁红飞 · 第1周',
    );
    expect(plan.items.length, 16);
  });

  test('空周次集合视为全学期 1..20', () {
    final plan = buildReminderPlan(
      spans: [span('不限周次的课', 1, 0, 0, '')],
      firstMonday: monday,
      periodTimes: times,
      leadMinutes: 10,
      now: DateTime(2026, 8, 1),
    );
    expect(plan.items.length, 20);
    expect(plan.items.last.body.endsWith('第20周'), isTrue);
  });

  test('缺失字段省略段落，正文不含空段', () {
    final plan = buildReminderPlan(
      spans: [CourseSpan('体育', '', '10', '', 5, startUnit: 6)],
      firstMonday: monday,
      periodTimes: times,
      leadMinutes: 10,
      now: DateTime(2026, 8, 1),
    );
    expect(plan.items.single.body, '第5节 14:00 · 第10周');
  });

  test('午休格（4/5 节）与提前跨午夜跳过', () {
    final plan = buildReminderPlan(
      spans: [
        span('午休课', 1, 4, 5, '1-16'),
        // 构造跨午夜：第 1 节 08:00 提前 500 分钟 = 前一天 00:20 -> fire<0 被跳
        span('离谱课', 1, 0, 1, '1-16'),
      ],
      firstMonday: monday,
      periodTimes: times,
      leadMinutes: 500,
      now: DateTime(2026, 8, 1),
    );
    expect(plan.items, isEmpty);
  });

  test('容量上限 450 截断并标记 overflow', () {
    final many = [
      for (var d = 1; d <= 7; d++)
        for (var u = 0; u <= 2; u++)
          span('课$d-$u', d, u, u, '', room: '', teacher: ''),
    ]; // 21 门 × 20 周 = 420 条 -> 不超
    final ok = buildReminderPlan(
      spans: many,
      firstMonday: monday,
      periodTimes: times,
      leadMinutes: 10,
      now: DateTime(2026, 8, 1),
    );
    expect(ok.overflow, isFalse);
    expect(ok.items.length, 420);

    final extra = [
      ...many,
      span('加课一', 1, 10, 11, '', room: '', teacher: ''),
      span('加课二', 2, 10, 11, '', room: '', teacher: ''),
    ]; // 23 门 × 20 周 = 460 候选 > 450
    final over = buildReminderPlan(
      spans: extra,
      firstMonday: monday,
      periodTimes: times,
      leadMinutes: 10,
      now: DateTime(2026, 8, 1),
    );
    expect(over.overflow, isTrue);
    expect(over.items.length, 450);
  });

  test('过去时刻剔除：now 之后的才保留', () {
    final plan = buildReminderPlan(
      spans: [span('线性代数', 1, 0, 1, '1-4')],
      firstMonday: monday,
      periodTimes: times,
      leadMinutes: 10,
      now: DateTime(2026, 9, 14, 8, 5), // 第 3 周周一 08:05：本周 07:50 已过
    );
    // 第 1-2 周已过、第 3 周 07:50 也已过（now 08:05），第 4 周（9/21）保留
    expect(plan.items.length, 1);
    expect(plan.items.single.body.endsWith('第4周'), isTrue);
  });
}
