// Engine | Flutter 3.x / Dart 3 | test/period_times_test.dart
// Run: flutter test

import 'package:flutter_test/flutter_test.dart';

import 'package:nuaa_eams/core/period_times.dart';

String _hm(int m) => formatMinutes(m);

void main() {
  test('三校区预设均为 11 节且自身合法', () {
    for (final c in campusNames) {
      final t = campusPreset(c);
      expect(t.length, periodCount, reason: c);
      expect(
        [for (final p in t) p.index],
        [for (var i = 1; i <= periodCount; i++) i],
        reason: c,
      );
      expect(hasInvalidPeriodTimes(t), isFalse, reason: c);
    }
  });

  test('将军路 2026-2027 第 1 学期作息页口径', () {
    final t = campusPreset('将军路');
    // 1/2 节
    expect(_hm(t[0].startMinutes), '08:00');
    expect(_hm(t[0].endMinutes), '08:50');
    expect(_hm(t[1].startMinutes), '08:55');
    // 3/4 节：错峰浮动，钉死 10:15-11:05 / 11:10-12:00
    expect(_hm(t[2].startMinutes), '10:15');
    expect(_hm(t[2].endMinutes), '11:05');
    expect(_hm(t[3].startMinutes), '11:10');
    expect(_hm(t[3].endMinutes), '12:00');
    // 下午 5-8 节
    expect(_hm(t[4].startMinutes), '14:00');
    expect(_hm(t[6].startMinutes), '16:15');
    expect(_hm(t[7].endMinutes), '18:00');
    // 晚上 9-11 节
    expect(_hm(t[8].startMinutes), '18:45');
    expect(_hm(t[10].startMinutes), '20:35');
    expect(_hm(t[10].endMinutes), '21:25');
  });

  test('明故宫与将军路作息一致', () {
    final j = campusPreset('将军路');
    final m = campusPreset('明故宫');
    for (var i = 0; i < periodCount; i++) {
      expect(m[i].startMinutes, j[i].startMinutes, reason: '第${i + 1}节');
      expect(m[i].endMinutes, j[i].endMinutes, reason: '第${i + 1}节');
    }
  });

  test('天目湖口径：1 节 08:30 起，三四节错峰 10:30 / 11:25', () {
    final t = campusPreset('天目湖');
    expect(_hm(t[0].startMinutes), '08:30');
    expect(_hm(t[1].endMinutes), '10:15');
    expect(_hm(t[2].startMinutes), '10:30');
    expect(_hm(t[2].endMinutes), '11:20');
    expect(_hm(t[3].startMinutes), '11:25');
    expect(_hm(t[3].endMinutes), '12:15');
    expect(_hm(t[6].startMinutes), '16:00');
    expect(_hm(t[7].endMinutes), '17:45');
    expect(_hm(t[8].startMinutes), '18:45');
  });

  test('未知校区回退默认校区', () {
    final a = campusPreset('不存在的校区');
    final b = campusPreset(defaultCampus);
    expect(a[0].startMinutes, b[0].startMinutes);
  });

  test('formatMinutes 补零 + 越界钳制', () {
    expect(formatMinutes(480), '08:00');
    expect(formatMinutes(1305), '21:45');
    expect(formatMinutes(-1), '00:00');
    expect(formatMinutes(24 * 60), '23:59');
  });

  test('fromJson 归一化：结束<=开始 先试 +45 分钟', () {
    final a = PeriodTime.fromJson({
      'index': 2,
      'startMinutes': 480,
      'endMinutes': 470,
    });
    expect(a.startMinutes, 480);
    expect(a.endMinutes, 525);

    // 23:59 开始 +45 放不下：整节退回默认 08:00-08:45
    final b = PeriodTime.fromJson({
      'index': 1,
      'startMinutes': 1439,
      'endMinutes': 100,
    });
    expect(b.startMinutes, 480);
    expect(b.endMinutes, 525);
  });

  test('fromJson 越界钳制与缺省', () {
    final t = PeriodTime.fromJson({
      'index': 3,
      'startMinutes': 25 * 60,
      'endMinutes': 'x',
    });
    expect(t.index, 1);
    expect(t.startMinutes, 8 * 60);
    expect(t.endMinutes, 8 * 60 + 45);
    expect(PeriodTime.fromJson({}).index, 1);
  });

  test('envelope 往返 + 裸数组导入（与 Sked 模板互通）', () {
    final src = campusPreset('将军路');
    final json = encodePeriodTimesJson(src);
    expect(json.contains('"schema":"period-times"'), isTrue);

    final back = decodePeriodTimesJson(json);
    expect(back.length, src.length);
    for (var i = 0; i < src.length; i++) {
      expect(back[i].index, src[i].index);
      expect(back[i].startMinutes, src[i].startMinutes);
      expect(back[i].endMinutes, src[i].endMinutes);
    }

    final bare = decodePeriodTimesJson(
      '[{"index":1,"startMinutes":540,"endMinutes":585}]',
    );
    expect(bare.single.startMinutes, 540);
  });

  test('非法模板报 FormatException', () {
    expect(() => decodePeriodTimesJson(''), throwsFormatException);
    expect(() => decodePeriodTimesJson('[]'), throwsFormatException);
    expect(() => decodePeriodTimesJson('not json'), throwsFormatException);
    expect(
      () => decodePeriodTimesJson('{"schema":"other","data":{}}'),
      throwsFormatException,
    );
  });

  test('alignPeriodTimes：截断/补尾/重排 index', () {
    final src = campusPreset('将军路');
    final trimmed = alignPeriodTimes(src.sublist(0, 3));
    expect(trimmed.length, periodCount);
    expect(trimmed[0].startMinutes, src[0].startMinutes);
    expect(trimmed[3].startMinutes, src[3].startMinutes); // 尾部用默认校区补
    expect(
      [for (final p in trimmed) p.index],
      [for (var i = 1; i <= periodCount; i++) i],
    );
  });

  test('hasInvalidPeriodTimes：结束早于开始 / 与上一节重叠', () {
    final ok = campusPreset('天目湖');
    expect(hasInvalidPeriodTimes(ok), isFalse);

    final badEnd = List.of(ok)
      ..[2] = ok[2].copyWith(endMinutes: ok[2].startMinutes);
    expect(hasInvalidPeriodTimes(badEnd), isTrue);

    final overlap = List.of(ok)
      ..[1] = ok[1].copyWith(startMinutes: ok[0].startMinutes);
    expect(hasInvalidPeriodTimes(overlap), isTrue);
  });
}
