// Engine | Flutter 3.x / Dart 3 | lib/core/current_semester.dart
// 服务端确认的"当前学期"共享存储：课表页写入（courseTable 响应带
// currentWeek 时），其余页面读取作为学期下拉的默认选中
// Build: 无（随应用编译）
// Deps: shared_preferences

import 'package:shared_preferences/shared_preferences.dart';

class CurrentSemester {
  static const _key = 'tt_cur_sem';

  /// 服务端确认过的当前学期 id；课表尚未成功加载过时为 null。
  /// [timeout] 非 0 时轮询等待——新装首启时考试/选课页先于课表首响 init，
  /// 稍等课表把值写进来，避免默认落到列表第一项（可能是未来学期）
  static Future<String?> id({
    Duration timeout = Duration.zero,
    Duration step = const Duration(milliseconds: 300),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final v = (await SharedPreferences.getInstance()).getString(_key);
      if (v != null || DateTime.now().isAfter(deadline)) return v;
      await Future.delayed(step);
    }
  }

  static Future<void> set(String id) async =>
      (await SharedPreferences.getInstance()).setString(_key, id);
}
