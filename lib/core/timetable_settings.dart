// Engine | Flutter 3.x / Dart 3 | lib/core/timetable_settings.dart
// 课表显示设置：列（周六/周日独立开关）、非本周课隐藏、课卡对齐
// （水平/垂直居中独立）、行高、列宽模式（塞满屏幕 / 最小列宽横向滚动）、
// 时间栏时刻、课卡内容（教室/老师/周次标注）。
//   - 单例 + revision 通知：设置页写入，课表页监听即时重绘
//   - 所有值有合法性钳制，坏配置不会崩
// Deps: shared_preferences

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 行高允许范围（用户可输入，越界钳制）
const rowHeightMin = 56.0;
const rowHeightMax = 128.0;
const rowHeightDefault = 80.0;

class TimetableSettings {
  TimetableSettings._();
  static final instance = TimetableSettings._();

  /// 任一设置变化 +1（课表页监听重绘）
  final ValueNotifier<int> revision = ValueNotifier(0);

  var _loaded = false;

  // 列
  var showSaturday = true;
  var showSunday = true;

  // 内容
  var showNonCurrentWeek = true; // false = 非本周课直接隐藏（选具体周时）
  var cardShowRoom = true;
  var cardShowTeacher = false;
  var cardShowWeeksTag = true; // 全部周视图里课卡的"N周"角标
  var showRailTimes = true; // 时间栏的上下课时刻小字

  // 布局
  var cardCenterH = false; // 课卡文字水平居中
  var cardCenterV = false; // 课卡文字垂直居中
  var fitWidth = false; // true = 列宽塞满屏幕（不横向滚动）；false = 最小列宽+滚动
  var rowHeight = rowHeightDefault;

  /// 当前应显示的星期（1=周一..7=周日）
  List<int> get visibleDays {
    if (showSaturday && showSunday) return const [1, 2, 3, 4, 5, 6, 7];
    if (showSaturday) return const [1, 2, 3, 4, 5, 6];
    if (showSunday) return const [1, 2, 3, 4, 5, 7];
    return const [1, 2, 3, 4, 5];
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      showSaturday = p.getBool('tt_set_show_sat') ?? true;
      showSunday = p.getBool('tt_set_show_sun') ?? true;
      showNonCurrentWeek = p.getBool('tt_set_show_noncur') ?? true;
      cardShowRoom = p.getBool('tt_set_card_room') ?? true;
      cardShowTeacher = p.getBool('tt_set_card_teacher') ?? false;
      cardShowWeeksTag = p.getBool('tt_set_card_weeks') ?? true;
      showRailTimes = p.getBool('tt_set_rail_times') ?? true;
      cardCenterH = p.getBool('tt_set_card_ch') ?? false;
      cardCenterV = p.getBool('tt_set_card_cv') ?? false;
      fitWidth = p.getBool('tt_set_fit_width') ?? false;
      rowHeight = (p.getDouble('tt_set_row_h') ?? rowHeightDefault).clamp(
        rowHeightMin,
        rowHeightMax,
      );
    } catch (_) {}
    revision.value++;
  }

  Future<void> _set(String key, Object value) async {
    try {
      final p = await SharedPreferences.getInstance();
      if (value is bool) {
        await p.setBool(key, value);
      } else if (value is double) {
        await p.setDouble(key, value);
      }
    } catch (_) {}
    revision.value++;
  }

  Future<void> setShowSaturday(bool v) async {
    showSaturday = v;
    await _set('tt_set_show_sat', v);
  }

  Future<void> setShowSunday(bool v) async {
    showSunday = v;
    await _set('tt_set_show_sun', v);
  }

  Future<void> setShowNonCurrentWeek(bool v) async {
    showNonCurrentWeek = v;
    await _set('tt_set_show_noncur', v);
  }

  Future<void> setCardShowRoom(bool v) async {
    cardShowRoom = v;
    await _set('tt_set_card_room', v);
  }

  Future<void> setCardShowTeacher(bool v) async {
    cardShowTeacher = v;
    await _set('tt_set_card_teacher', v);
  }

  Future<void> setCardShowWeeksTag(bool v) async {
    cardShowWeeksTag = v;
    await _set('tt_set_card_weeks', v);
  }

  Future<void> setShowRailTimes(bool v) async {
    showRailTimes = v;
    await _set('tt_set_rail_times', v);
  }

  Future<void> setCardCenterH(bool v) async {
    cardCenterH = v;
    await _set('tt_set_card_ch', v);
  }

  Future<void> setCardCenterV(bool v) async {
    cardCenterV = v;
    await _set('tt_set_card_cv', v);
  }

  Future<void> setFitWidth(bool v) async {
    fitWidth = v;
    await _set('tt_set_fit_width', v);
  }

  Future<void> setRowHeight(double v) async {
    rowHeight = v.clamp(rowHeightMin, rowHeightMax);
    await _set('tt_set_row_h', rowHeight);
  }
}
