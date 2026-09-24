// Engine | Flutter 3.x / Dart 3 | test/update_check_test.dart
// Run: flutter test

import 'package:flutter_test/flutter_test.dart';

import 'package:nuaa_eams/core/app_updater.dart';

void main() {
  group('parseVersion', () {
    test('带/不带 v 前缀、多段', () {
      expect(parseVersion('v2.0.1'), [2, 0, 1]);
      expect(parseVersion('V2.0.1'), [2, 0, 1]);
      expect(parseVersion('2.0.1'), [2, 0, 1]);
      expect(parseVersion('2.0'), [2, 0]);
      expect(parseVersion(' 3.11.3 '), [3, 11, 3]);
    });

    test('非法输入返回 null', () {
      expect(parseVersion(''), isNull);
      expect(parseVersion('v'), isNull);
      expect(parseVersion('2.0.x'), isNull);
      expect(parseVersion('v2.0.0-beta'), isNull);
    });
  });

  group('isNewer', () {
    test('基本新旧判断', () {
      expect(isNewer('2.0.0', 'v2.0.1'), isTrue);
      expect(isNewer('2.0.0', '2.0.0'), isFalse);
      expect(isNewer('2.0.1', 'v2.0.0'), isFalse);
      expect(isNewer('2.0.0', '1.99.99'), isFalse);
    });

    test('数值比较而非字典序（两位段）', () {
      expect(isNewer('2.9.9', 'v2.10.0'), isTrue);
      expect(isNewer('2.10.0', 'v2.9.9'), isFalse);
      expect(isNewer('9.0.0', 'v10.0.0'), isTrue);
    });

    test('段数不足补 0', () {
      expect(isNewer('2.0', 'v2.0.1'), isTrue);
      expect(isNewer('2.0.1', 'v2.0'), isFalse);
      expect(isNewer('2.0', 'v2.0.0'), isFalse);
    });

    test('解析失败一律不提示更新', () {
      expect(isNewer('2.0.0', 'v2.0.0-beta'), isFalse);
      expect(isNewer('', 'v2.0.0'), isFalse);
      expect(isNewer('2.0.0', 'garbage'), isFalse);
    });
  });

  test('仓库常量指向 shiywhh/i-niuaa', () {
    expect(repoSlug, 'shiywhh/i-niuaa');
    expect(releasesUrl, 'https://github.com/shiywhh/i-niuaa/releases');
  });
}
