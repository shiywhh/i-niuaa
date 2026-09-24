// Engine | Flutter 3.x / Dart 3 | lib/core/period_times.dart
// 节次时间：模型 + 三校区作息预设 + 本地存储（编辑器交互抄自 Sked）。
//   - 固定 11 节，与课表时间栏的显示行一一对应（午休 4/5 节不占行）
//   - 预设取自 aao-eas「作息时间」页（2026-2027 学年第 1 学期）：
//     将军路/明故宫同口径；三、四节页面标"错峰浮动时间"，
//     将军路/明故宫取 10:15/11:10，天目湖取 10:30/11:25
//   - 模板 JSON 用 Sked 的 period-times envelope（schema 'period-times'，
//     version 3），与 Sked 导出的模板直接互通
// Deps: shared_preferences

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一节课的上下课时刻（当天第几分钟，0 起）
class PeriodTime {
  final int index; // 第几节（1 起）
  final int startMinutes;
  final int endMinutes;

  const PeriodTime({
    required this.index,
    required this.startMinutes,
    required this.endMinutes,
  });

  PeriodTime copyWith({int? index, int? startMinutes, int? endMinutes}) =>
      PeriodTime(
        index: index ?? this.index,
        startMinutes: startMinutes ?? this.startMinutes,
        endMinutes: endMinutes ?? this.endMinutes,
      );

  Map<String, dynamic> toJson() => {
    'index': index,
    'startMinutes': startMinutes,
    'endMinutes': endMinutes,
  };

  /// 与 Sked 同口径的归一化：越界钳到当天；结束 <= 开始时先试 +45 分钟
  /// 修复，放不下（开始已是 23:59 附近）整节退回默认 08:00-08:45
  factory PeriodTime.fromJson(Map<String, dynamic> j) {
    final start = _norm(j['startMinutes'], 8 * 60);
    final rawEnd = _norm(j['endMinutes'], 8 * 60 + 45);
    if (rawEnd > start) {
      return PeriodTime(
        index: (j['index'] as num?)?.toInt() ?? 1,
        startMinutes: start,
        endMinutes: rawEnd,
      );
    }
    final repaired = (start + 45).clamp(0, 24 * 60 - 1);
    if (repaired > start) {
      return PeriodTime(
        index: (j['index'] as num?)?.toInt() ?? 1,
        startMinutes: start,
        endMinutes: repaired,
      );
    }
    return const PeriodTime(
      index: 1,
      startMinutes: 8 * 60,
      endMinutes: 8 * 60 + 45,
    );
  }

  static int _norm(dynamic v, int fallback) =>
      v is num && v.isFinite ? v.toInt().clamp(0, 24 * 60 - 1) : fallback;
}

/// 分钟数 -> "HH:MM"（与 Sked formatMinutes 同输出）
String formatMinutes(int minutes) {
  final m = minutes.clamp(0, 24 * 60 - 1);
  final hour = (m ~/ 60).toString().padLeft(2, '0');
  final minute = (m % 60).toString().padLeft(2, '0');
  return '$hour:$minute';
}

// ---------- 三校区作息预设 ----------

/// 全部节次时间的节数（与课表 _displayUnits 的行数一致）
const periodCount = 11;

/// 校区预设名（顺序即选择器顺序）
const campusNames = <String>['将军路', '明故宫', '天目湖'];
const defaultCampus = '将军路';

/// [时, 分, 时, 分] × 11 节；三四节为错峰浮动，按校区钉死取值
const _jjlSlots = <List<int>>[
  [8, 0, 8, 50],
  [8, 55, 9, 45],
  [10, 15, 11, 5],
  [11, 10, 12, 0],
  [14, 0, 14, 50],
  [14, 55, 15, 45],
  [16, 15, 17, 5],
  [17, 10, 18, 0],
  [18, 45, 19, 35],
  [19, 40, 20, 30],
  [20, 35, 21, 25],
];

// 明故宫与将军路作息页完全一致
const _mggSlots = _jjlSlots;

const _tmhSlots = <List<int>>[
  [8, 30, 9, 20],
  [9, 25, 10, 15],
  [10, 30, 11, 20],
  [11, 25, 12, 15],
  [14, 0, 14, 50],
  [14, 55, 15, 45],
  [16, 0, 16, 50],
  [16, 55, 17, 45],
  [18, 45, 19, 35],
  [19, 40, 20, 30],
  [20, 35, 21, 25],
];

const _campusSlots = <String, List<List<int>>>{
  '将军路': _jjlSlots,
  '明故宫': _mggSlots,
  '天目湖': _tmhSlots,
};

/// 校区预设作息；未知校区名回退默认校区
List<PeriodTime> campusPreset(String campus) {
  final slots = _campusSlots[campus] ?? _campusSlots[defaultCampus]!;
  return List.generate(
    periodCount,
    (i) => PeriodTime(
      index: i + 1,
      startMinutes: slots[i][0] * 60 + slots[i][1],
      endMinutes: slots[i][2] * 60 + slots[i][3],
    ),
  );
}

/// 存在非法节（结束 <= 开始，或与上一节重叠）时为 true；
/// 与 Sked 同策略：有非法行时不落盘，等改合法再存
bool hasInvalidPeriodTimes(List<PeriodTime> times) {
  for (var i = 0; i < times.length; i++) {
    if (times[i].endMinutes <= times[i].startMinutes) return true;
    if (i > 0 && times[i].startMinutes < times[i - 1].endMinutes) return true;
  }
  return false;
}

// ---------- 模板 JSON（Sked period-times envelope 兼容） ----------

const _envelopeSchema = 'period-times';
const _envelopeVersion = 3;

/// 编码成 Sked 可识别的模板 JSON
String encodePeriodTimesJson(List<PeriodTime> times) => jsonEncode({
  'schema': _envelopeSchema,
  'version': _envelopeVersion,
  'data': {
    'periodTimes': [for (final t in times) t.toJson()],
  },
});

/// 解析模板 JSON：完整 envelope 或裸数组 [{index,startMinutes,endMinutes},...]
/// 均可；导入后调用方按需截断/补齐到 [periodCount] 节
List<PeriodTime> decodePeriodTimesJson(String source) {
  final trimmed = source.trim();
  if (trimmed.isEmpty) throw const FormatException('内容为空');
  final Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException {
    throw const FormatException('不是合法的 JSON');
  }
  final List raw;
  if (decoded is List) {
    raw = decoded;
  } else if (decoded is Map) {
    final data = decoded['data'];
    if (decoded['schema'] != _envelopeSchema || data is! Map) {
      throw const FormatException('不是节次时间模板');
    }
    raw = data['periodTimes'] as List? ?? const [];
  } else {
    throw const FormatException('不是节次时间模板');
  }
  final times = <PeriodTime>[
    for (final e in raw)
      if (e is Map) PeriodTime.fromJson(e.cast<String, dynamic>()),
  ];
  if (times.isEmpty) throw const FormatException('模板里没有节次时间');
  return times;
}

/// 导入模板对齐到固定节数：多了截断，少了用默认校区预设补尾；
/// index 重排 1..N
List<PeriodTime> alignPeriodTimes(List<PeriodTime> times) {
  final defaults = campusPreset(defaultCampus);
  return List.generate(periodCount, (i) {
    final src = i < times.length ? times[i] : defaults[i];
    return src.copyWith(index: i + 1);
  });
}

// ---------- 存储：SharedPreferences + 变更通知 ----------

/// 单例存储：设置页写入，课表页监听 [revision] 刷新时间栏
class PeriodTimesStore {
  PeriodTimesStore._();
  static final instance = PeriodTimesStore._();

  static const _key = 'period_times_v1';
  static const _campusKey = 'period_times_campus_v1';

  /// 每次 +1 表示时间表变了（含首次加载完成）
  final ValueNotifier<int> revision = ValueNotifier(0);

  List<PeriodTime> _times = const [];
  var _loaded = false;
  String _campus = defaultCampus;

  /// 当前时间表（未加载时为空表；只读，改动走 [save]）
  List<PeriodTime> get times => _times;

  /// 当前校区预设名（手动改时刻不改它，仅作"基准校区"标记）
  String get campus => _campus;

  /// 第 [index] 节（1 起）；未加载或缺节返回 null
  PeriodTime? of(int index) {
    if (index < 1 || index > _times.length) return null;
    return _times[index - 1];
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    var list = <PeriodTime>[];
    try {
      final p = await SharedPreferences.getInstance();
      final s = p.getString(_key);
      if (s != null) {
        list = [
          for (final e in (jsonDecode(s) as List))
            if (e is Map) PeriodTime.fromJson(e.cast<String, dynamic>()),
        ];
      }
      final c = p.getString(_campusKey);
      _campus = campusNames.contains(c) ? c! : defaultCampus;
    } catch (_) {}
    _times = list.length == periodCount ? list : campusPreset(_campus);
    revision.value++;
  }

  /// 写内存 + 写磁盘；磁盘失败不影响本次会话显示
  Future<void> save(List<PeriodTime> times) async {
    _times = List.of(times);
    revision.value++;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
        _key,
        jsonEncode([for (final t in times) t.toJson()]),
      );
    } catch (_) {}
  }

  /// 切换校区：应用该校区预设作息并记住选择
  Future<void> selectCampus(String name) async {
    _campus = campusNames.contains(name) ? name : defaultCampus;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_campusKey, _campus);
    } catch (_) {}
    await save(campusPreset(_campus));
  }
}
