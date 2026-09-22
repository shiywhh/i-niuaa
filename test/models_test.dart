// Engine | Flutter 3.x / Dart 3 | test/models_test.dart
// Run: flutter test

import 'package:flutter_test/flutter_test.dart';

import 'package:nuaa_eams/core/models.dart';

void main() {
  group('CourseSpan.parseWeeks', () {
    test('区间 + 单周', () {
      expect(CourseSpan.parseWeeks('6-16,18'),
          {6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18});
      expect(CourseSpan.parseWeeks('7-16,18-19'), {
        7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 19,
      });
    });

    test('单周与空串', () {
      expect(CourseSpan.parseWeeks('1'), {1});
      expect(CourseSpan.parseWeeks(''), isEmpty);
      expect(CourseSpan.parseWeeks('abc'), isEmpty);
    });
  });

  test('CourseSpan JSON 往返（跨节时段）', () {
    final c = CourseSpan('线性代数', '胡志成', '7-16', '10107(将军路)', 1,
        startUnit: 6, endUnit: 7);
    final back = CourseSpan.fromJson(c.toJson());
    expect(back.name, c.name);
    expect(back.teacher, c.teacher);
    expect(back.weeks, c.weeks);
    expect(back.room, c.room);
    expect(back.weekday, c.weekday);
    expect(back.startUnit, 6);
    expect(back.endUnit, 7);
    expect(back.durationUnits, 2);
  });

  test('CourseSpan 单节时段（endUnit 缺省 = startUnit）', () {
    final c = CourseSpan('体育', '', '1-16', '田场馆', 5, startUnit: 6);
    expect(c.startUnit, 6);
    expect(c.endUnit, 6);
    expect(c.durationUnits, 1);
    final back = CourseSpan.fromJson(c.toJson());
    expect(back.startUnit, 6);
    expect(back.endUnit, 6);
  });

  group('PayCodeBatch 付款码轮换', () {
    final t0 = DateTime(2026, 9, 20, 12);

    PayCodeBatch batch({int n = 3, int expires = 120}) => PayCodeBatch(
          codes: List.generate(n, (i) => 'CODE$i'),
          expiresSeconds: expires,
          fetchedAt: t0,
        );

    test('批次内按时间窗口轮换', () {
      final b = batch();
      expect(b.codeAt(t0), 'CODE0');
      expect(b.codeAt(t0.add(const Duration(seconds: 119))), 'CODE0');
      expect(b.codeAt(t0.add(const Duration(seconds: 120))), 'CODE1');
      expect(b.codeAt(t0.add(const Duration(seconds: 240))), 'CODE2');
      expect(b.indexAt(t0.add(const Duration(seconds: 250))), 2);
    });

    test('剩余秒数', () {
      final b = batch();
      expect(b.secondsLeftAt(t0.add(const Duration(seconds: 30))), 90);
      expect(b.secondsLeftAt(t0.add(const Duration(seconds: 120))), 120);
      expect(b.secondsLeftAt(t0.add(const Duration(seconds: 250))), 110);
    });

    test('批次用尽返回 null/-1', () {
      final b = batch();
      expect(b.codeAt(t0.add(const Duration(seconds: 360))), isNull);
      expect(b.indexAt(t0.add(const Duration(seconds: 360))), -1);
      expect(b.secondsLeftAt(t0.add(const Duration(seconds: 360))), 0);
    });

    test('空批次与非法过期时间', () {
      final e = PayCodeBatch(codes: [], expiresSeconds: 120, fetchedAt: t0);
      expect(e.codeAt(t0), isNull);
      final z = PayCodeBatch(codes: ['A'], expiresSeconds: 0, fetchedAt: t0);
      expect(z.codeAt(t0), isNull);
    });

    test('时钟回拨（本机略慢）按第 0 个窗口处理', () {
      final b = batch();
      expect(b.indexAt(t0.subtract(const Duration(seconds: 5))), 0);
    });

    test('JSON 往返', () {
      final b = PayCodeBatch(
        codes: ['40008725247522449421', '40308884262805530909'],
        expiresSeconds: 120,
        fetchedAt: t0,
      );
      final back = PayCodeBatch.fromJson(b.toJson());
      expect(back.codes, b.codes);
      expect(back.expiresSeconds, 120);
      expect(back.fetchedAt, t0);
      expect(back.codeAt(t0.add(const Duration(seconds: 120))),
          '40308884262805530909');
    });
  });
}
