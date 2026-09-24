// Engine | Flutter 3.x / Dart 3 | lib/ui/timetable_page.dart
// 周视图课表：学期切换 + 教学周筛选，行高 80。滚动结构同 Sked：
// 表头纵向固定、横向与表体经 controller listener 同步（防回环）；
// 纵向只有单一 viewport，时间栏内嵌其中，结构上锁死无需同步。
//   - 一门课一个时段：跨 N 节的课一张卡跨格画（Sked 式时段模型）
//   - 重叠组单一渲染路径：组内选中一张全浓度卡，多门时角标 + 点击轮换
//     （在上的课优先），其余成员画无字底块露形状；重叠按显示行判定
//     （相邻共节、午休折叠格都算）
//   - 周次三态：在上（正常）/ 未开始（淡彩）/ 已结束（灰），不再是二值过滤
//   - 学期锚点：首次拿到服务端"教学周"时反推学期第一周的周一存本地，
//     之后日期表头与真实周次全靠锚点本地推算（离线、历史学期都可用）
//   - 缓存 stale-while-revalidate：按学期分 key，进页面先渲染缓存再静默刷新

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/current_semester.dart';
import '../core/models.dart';
import '../core/period_times.dart';
import '../core/session.dart';
import '../core/timetable_ics.dart' show TimetableSnapshot, unitToPeriod;
import '../core/timetable_settings.dart';

/// 选中的教学周里一门课的状态
enum _SpanState { active, futureInactive, pastEnded }

/// 缓存命中：数据 + 缓存时刻
class _Cached {
  final CourseTableData data;
  final DateTime? at;
  _Cached(this.data, this.at);
}

/// 单元号 → 显示行号（跳过午休段 4/5；4、5 兜底折叠到 3、4 行）
int _rowOf(int unit) {
  if (unit <= 3) return unit;
  if (unit >= 6) return unit - 2;
  return unit - 1; // 午段数据兜底
}

class TimetablePage extends StatefulWidget {
  /// 非 null 时由外部（HomeShell 的 AppBar 按钮）控制顶部两行收起/展开
  final ValueNotifier<bool>? collapsed;

  const TimetablePage({super.key, this.collapsed});

  @override
  State<TimetablePage> createState() => _TimetablePageState();
}

class _TimetablePageState extends State<TimetablePage> {
  List<Semester> _semesters = [];
  String? _semId; // null = 当前学期
  String? _semName;
  int? _curWeek; // 服务端给的当前教学周（仅当前学期有）
  String? _curSemId; // 服务端确认的"当前学期" id（courseTable 返回）
  List<CourseSpan> _spans = [];
  List<CourseListItem> _courseList = const [];
  int _week = 0; // 0 = 全部周次
  bool _weekTouched = false; // 用户手动选过周次后，刷新不再覆盖
  bool _loading = true;
  String? _error;
  String? _loadedKey; // 当前展示的数据对应的学期 key
  bool _stale = false; // 刷新失败，正在展示缓存/旧数据
  DateTime? _cacheAt; // 缓存数据的时刻
  DateTime? _anchor; // 所选学期第 1 周的周一（本地推算基准）
  int _loadSeq = 0; // 加载代际号：加载中又触发新加载时，旧响应/旧错误整体作废
  Timer? _tick; // 每分钟一跳：今日高亮 / 进行中节次 / 下节课提示

  static const _cachePrefix = 'tt_cache_v3_';
  static const _anchorPrefix = 'tt_anchor_';

  static const _palette = [
    Color(0xFF4C78A8),
    Color(0xFFF58518),
    Color(0xFF54A24B),
    Color(0xFFB279A2),
    Color(0xFFE45756),
    Color(0xFF72B7B2),
    Color(0xFF9D755D),
  ];

  /// 一天 13 个单元（4/5 为午一、午二），跳过午休逐节显示
  static const _displayUnits = [0, 1, 2, 3, 6, 7, 8, 9, 10, 11, 12];

  // 横向同步（Sked 式）：listener + 防回环标志。纵向只有单一 viewport，
  // 时间栏内嵌其中，无需任何同步。
  final ScrollController _headHCtrl = ScrollController();
  final ScrollController _bodyHCtrl = ScrollController();
  bool _syncingH = false;
  bool _hClampScheduled = false;

  /// 完全冲突组的当前展示选择：'$d:$start-$end' -> 第几个
  final Map<String, int> _conflictPick = {};

  Color _colorOf(String name) =>
      _palette[name.hashCode.abs() % _palette.length];

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  void _onCollapsedChanged() {
    if (mounted) setState(() {});
  }

  bool get _headerCollapsed => widget.collapsed?.value ?? false;

  @override
  void initState() {
    super.initState();
    _headHCtrl.addListener(_syncHeadToBody);
    _bodyHCtrl.addListener(_syncBodyToHead);
    widget.collapsed?.addListener(_onCollapsedChanged);
    // 节次时间：首次加载 + 设置页保存后刷新时间栏
    PeriodTimesStore.instance.revision.addListener(_onPeriodTimesChanged);
    PeriodTimesStore.instance.ensureLoaded();
    // 显示设置：设置页改动即时重绘；每分钟一跳刷新"进行中/下节课"
    TimetableSettings.instance.revision.addListener(_onPeriodTimesChanged);
    TimetableSettings.instance.load();
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    _load();
  }

  void _onPeriodTimesChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant TimetablePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.collapsed != oldWidget.collapsed) {
      oldWidget.collapsed?.removeListener(_onCollapsedChanged);
      widget.collapsed?.addListener(_onCollapsedChanged);
    }
    _scheduleHorizontalClamp();
  }

  @override
  void dispose() {
    PeriodTimesStore.instance.revision.removeListener(_onPeriodTimesChanged);
    TimetableSettings.instance.revision.removeListener(_onPeriodTimesChanged);
    _tick?.cancel();
    widget.collapsed?.removeListener(_onCollapsedChanged);
    _headHCtrl
      ..removeListener(_syncHeadToBody)
      ..dispose();
    _bodyHCtrl
      ..removeListener(_syncBodyToHead)
      ..dispose();
    super.dispose();
  }

  void _syncHeadToBody() => _syncHorizontal(_headHCtrl, _bodyHCtrl);

  void _syncBodyToHead() => _syncHorizontal(_bodyHCtrl, _headHCtrl);

  void _syncHorizontal(ScrollController src, ScrollController dst) {
    if (_syncingH || !src.hasClients || !dst.hasClients) return;
    if (!src.position.hasContentDimensions ||
        !dst.position.hasContentDimensions) {
      return;
    }
    final target = src.offset.clamp(
      dst.position.minScrollExtent,
      dst.position.maxScrollExtent,
    );
    if ((dst.offset - target).abs() < 0.5) return;
    _syncingH = true;
    dst.jumpTo(target);
    _syncingH = false;
  }

  /// viewport 尺寸变化后，把两个横向 offset 收敛到同一有效值
  /// （比如窗口变宽到不再需要横向滚动时，清掉残留偏移）
  void _scheduleHorizontalClamp() {
    if (_hClampScheduled) return;
    _hClampScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hClampScheduled = false;
      if (!mounted) return;
      final controllers = [
        _headHCtrl,
        _bodyHCtrl,
      ].where((c) => c.hasClients && c.position.hasContentDimensions).toList();
      if (controllers.isEmpty) return;
      final collapsed = controllers.any((c) => c.position.maxScrollExtent <= 0);
      final desired = collapsed
          ? 0.0
          : controllers.map((c) => c.offset).reduce(math.min);
      _syncingH = true;
      for (final c in controllers) {
        final clamped = desired.clamp(
          c.position.minScrollExtent,
          c.position.maxScrollExtent,
        );
        if ((c.offset - clamped).abs() >= 0.5) c.jumpTo(clamped);
      }
      _syncingH = false;
    });
  }

  // ---------- 数据装载：先缓存秒开，再静默刷新 ----------

  Future<void> _load() async {
    // 代际号：只允许最新一次加载的响应/错误上屏
    final seq = ++_loadSeq;
    // 用户显式锁定过学期（切换学期）才按学期取；冷启动一律按"当前学期"取，
    // 保证每次打开软件都落在当前学期
    final picked = _semId != null;
    // 1) 缓存优先：先展示已知的当前学期，
    //    旧版本兜底 tt_last_sem，都没有则直接走网络
    final p = await _prefs;
    final wantKey =
        _semId ?? await CurrentSemester.id() ?? p.getString('tt_last_sem');
    final cached = await _readCache(wantKey);
    if (cached != null) {
      // 锚点先行：_apply 选周优先按今天日期从锚点推算本周，
      // 缓存里的 curWeek 只是快照，避免秒开帧闪旧周次
      final anchor = await _readAnchor(wantKey!);
      if (!mounted || seq != _loadSeq) return;
      _anchor = anchor;
      setState(() => _apply(cached.data, cacheAt: cached.at, key: wantKey));
    } else if (seq == _loadSeq &&
        mounted &&
        (_loadedKey != wantKey || _spans.isEmpty)) {
      // 无缓存且目标不是正在显示的学期 → 清屏，避免旧学期数据串台
      setState(() {
        _spans = [];
        _loading = true;
        _error = null;
        _cacheAt = null;
      });
    }

    // 2) 网络刷新（guard 内含会话过期重登）
    try {
      final data = await Session.I.guard(
        () => Session.I.eams.courseTable(semesterId: picked ? _semId : null),
      );
      // 冷启动展示的缓存学期可能已被服务端换掉（换学期/旧版 tt_last_sem 兜底）：
      // 放弃旧认领，让 _apply 重新选中当前学期并自动跳到本周。
      // _semId != wantKey 说明缓存恢复后用户刚手动切过学期，不碰。
      if (!picked &&
          _semId != null &&
          _semId == wantKey &&
          data.semesterId.isNotEmpty &&
          data.semesterId != wantKey) {
        _semId = null;
      }
      final semKey = data.semesterId.isNotEmpty
          ? data.semesterId
          : (_semId ?? 'current');
      await _saveCache(semKey, data);
      if (data.currentWeek != null) {
        _anchor = await _saveAnchor(semKey, data.currentWeek!);
      } else {
        _anchor = await _readAnchor(semKey);
      }
      // 过期响应不上屏（期间用户又触发了别的加载）
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _apply(data, key: semKey);
        _cacheAt = null;
        _stale = false;
      });
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      if (_spans.isEmpty) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      } else {
        setState(() {
          _stale = true;
          _loading = false;
        });
      }
    }
  }

  void _apply(CourseTableData data, {DateTime? cacheAt, String? key}) {
    _loadedKey = key;
    if (data.semesters.isNotEmpty) _semesters = data.semesters;
    _semId = _semId ?? (data.semesterId.isNotEmpty ? data.semesterId : null);
    _semName = data.semesterName;
    // 仅当响应带 currentWeek（服务端只对"当前学期"给此字段）才确认当前学期，
    // 否则切到历史学期后会把请求的 semesterId 误记成当前学期
    if (data.currentWeek != null && data.semesterId.isNotEmpty) {
      _curSemId = data.semesterId;
      _curWeek = data.currentWeek;
    }
    _spans = data.spans;
    _courseList = data.courseList;
    _cacheAt = cacheAt;
    _loading = false;
    // 当前学期自动选中本周；历史学期回"全部"；用户手动选过则不覆盖。
    // 本周取值：服务端 currentWeek → 锚点/状态里的当前周 → 兜底"全部"；
    // 超出 1-20（假期）无法在周次下拉中表示，同样回"全部"
    final isCurrent = _semId == null || _semId == data.semesterId;
    if (!_weekTouched) {
      if (isCurrent) {
        // 有锚点优先按今天日期推算本周：缓存里的 curWeek 是写入时刻的快照，
        // 会随时间过期；锚点推算永远反映"今天"。无锚点才退回 currentWeek。
        final w = _anchor != null ? _realWeek : (data.currentWeek ?? _realWeek);
        _week = (w != null && w >= 1 && w <= 20) ? w : 0;
      } else {
        _week = 0;
      }
    }
    // 数据重载后冲突组的成员可能变化，轮换选择作废
    _conflictPick.clear();
    // 分享/导出入口（HomeShell AppBar）不直接依赖本页 state，喂一份快照
    TimetableSnapshot.semesterName = _semName ?? '当前学期';
    TimetableSnapshot.spans = _spans;
    TimetableSnapshot.firstMonday = _anchor;
  }

  /// [keepWeek]：回到本周的跨学期跳转用——保留当前周次选择，
  /// 不让加载完成后的自动选周覆盖用户意图
  Future<void> _switchSemester(String id, {bool keepWeek = false}) async {
    if (id == _semId) return;
    setState(() {
      _semId = id;
      _weekTouched = keepWeek && _weekTouched;
      _anchor = null;
    });
    await _load();
  }

  // ---------- 缓存 ----------

  Future<void> _saveCache(String semKey, CourseTableData data) async {
    try {
      final p = await _prefs;
      await p.setString(
        '$_cachePrefix$semKey',
        jsonEncode({
          'at': DateTime.now().toIso8601String(),
          'sem': data.semesterName,
          'curWeek': data.currentWeek,
          'spans': data.spans.map((c) => c.toJson()).toList(),
          'list': data.courseList.map((c) => c.toJson()).toList(),
        }),
      );
      await p.setString('tt_last_sem', semKey);
    } catch (_) {}
  }

  Future<_Cached?> _readCache(String? semKey) async {
    if (semKey == null || semKey.isEmpty) return null;
    try {
      final p = await _prefs;
      final s = p.getString('$_cachePrefix$semKey');
      if (s == null) return null;
      final j = (jsonDecode(s) as Map).cast<String, dynamic>();
      final data = CourseTableData(
        j['sem'] as String? ?? '当前学期',
        semKey,
        const [],
        (j['spans'] as List)
            .map((e) => CourseSpan.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
        j['curWeek'] as int?,
        ((j['list'] ?? const []) as List)
            .map(
              (e) =>
                  CourseListItem.fromJson((e as Map).cast<String, dynamic>()),
            )
            .toList(),
      );
      return _Cached(data, DateTime.tryParse(j['at'] as String? ?? ''));
    } catch (_) {
      return null;
    }
  }

  // ---------- 学期锚点：第 1 周的周一 ----------

  /// 服务端 currentWeek 只在当前学期出现：反推学期第一周的周一并存下，
  /// 之后周次与日期全靠锚点本地推算。返回锚点（第 1 周的周一），
  /// 是否落 state 由调用方按代际决定
  Future<DateTime> _saveAnchor(String semKey, int curWeek) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final monday = today.subtract(Duration(days: today.weekday - 1));
    final start = monday.subtract(Duration(days: (curWeek - 1) * 7));
    try {
      final p = await _prefs;
      await p.setString('$_anchorPrefix$semKey', start.toIso8601String());
      // 服务端确认的"当前学期"：冷启动缓存与各页面学期下拉默认值都以它为准
      await CurrentSemester.set(semKey);
    } catch (_) {}
    return start;
  }

  /// 读学期锚点。只读不落 state，是否采用由调用方按代际决定
  Future<DateTime?> _readAnchor(String? semKey) async {
    if (semKey == null || semKey.isEmpty) return null;
    try {
      final p = await _prefs;
      final s = p.getString('$_anchorPrefix$semKey');
      return s == null ? null : DateTime.tryParse(s);
    } catch (_) {
      return null;
    }
  }

  /// 真实教学周：有锚点用锚点推（任何学期、离线都行），否则退回服务端值
  int? get _realWeek {
    final a = _anchor;
    if (a != null) {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      return today.difference(a).inDays ~/ 7 + 1;
    }
    return _curWeek;
  }

  /// "回到本周"可用性：需要服务端确认过的当前学期与当前周；
  /// 学期不对或周不对时可点，两者都已就位时置灰
  bool get _canBackToCurrent {
    final w = _curWeek;
    if (_curSemId == null || w == null || w < 1 || w > 20) return false;
    if (_semId != _curSemId) return true;
    return _week != w;
  }

  /// 选周：周次一变，冲突组里“在上的课”可能换人，轮换选择清零
  void _setWeek(int w) {
    setState(() {
      _week = w;
      _weekTouched = true;
      _conflictPick.clear();
    });
  }

  /// 跳回当前学期 + 当前教学周。跨学期时先钉住目标周再切换，
  /// 加载完成后若仍被覆盖则纠正一次
  Future<void> _backToCurrent() async {
    if (!_canBackToCurrent) return;
    final sem = _curSemId!;
    final w = _curWeek!;
    if (_semId != sem) {
      _setWeek(w);
      await _switchSemester(sem, keepWeek: true);
      if (mounted && _week != w) _setWeek(w);
      return;
    }
    _setWeek(w);
  }

  // ---------- 周次三态 ----------

  /// 选中周不在课的周次集合里时，判断"还没上"还是"已经结了"。
  /// 周次集合为空 = 不限周次 = 永远在上。
  _SpanState _stateOf(CourseSpan c) {
    if (_week <= 0) return _SpanState.active;
    final ws = c.weekSet;
    if (ws.isEmpty || ws.contains(_week)) return _SpanState.active;
    final hasPast = ws.any((w) => w < _week);
    final hasFuture = ws.any((w) => w > _week);
    if (!hasFuture) return _SpanState.pastEnded;
    if (!hasPast) return _SpanState.futureInactive;
    final rw = _realWeek;
    if (rw == null) return _SpanState.futureInactive;
    return _week < rw ? _SpanState.pastEnded : _SpanState.futureInactive;
  }

  // ---------- 重叠分组 ----------

  /// 晚开始的课压上层（画在后面）；同时开始则短课压上层
  int _comparePaint(CourseSpan a, CourseSpan b) {
    final c = a.startUnit.compareTo(b.startUnit);
    if (c != 0) return c;
    final d = b.durationUnits.compareTo(a.durationUnits);
    if (d != 0) return d;
    return a.name.compareTo(b.name);
  }

  /// 完全冲突组内同状态课程的展示顺序：时长优先、晚开始优先
  int _compareDisplay(CourseSpan a, CourseSpan b) {
    final d = b.durationUnits.compareTo(a.durationUnits);
    if (d != 0) return d;
    final c = b.startUnit.compareTo(a.startUnit);
    if (c != 0) return c;
    return a.name.compareTo(b.name);
  }

  /// 显示行 inclusive：共享一行即同组（相邻共节、午休折叠格都算）；
  /// 链式搭接（A-B-C 依次共格）并入同组
  List<List<CourseSpan>> _overlapGroups(List<CourseSpan> daySpans) {
    final sorted = [...daySpans]..sort(_comparePaint);
    final groups = <List<CourseSpan>>[];
    var cur = <CourseSpan>[];
    var curEnd = -1; // 组内目前最大的显示行号
    for (final s in sorted) {
      final endRow = _rowOf(s.endUnit);
      if (cur.isEmpty || _rowOf(s.startUnit) <= curEnd) {
        cur.add(s);
        if (endRow > curEnd) curEnd = endRow;
      } else {
        groups.add(cur);
        cur = [s];
        curEnd = endRow;
      }
    }
    if (cur.isNotEmpty) groups.add(cur);
    return groups;
  }

  // ---------- 全部课程面板 ----------

  void _showAllCourses() {
    // 课表里有的课程才给颜色；没有的透明
    final inTable = _spans.map((c) => c.name).toSet();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '课程列表 · ${_courseList.length} 门',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _courseList.isEmpty
                  ? const Center(
                      child: Text(
                        '暂无课程列表数据',
                        style: TextStyle(color: Colors.black45),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(8),
                      itemCount: _courseList.length,
                      itemBuilder: (_, i) {
                        final c = _courseList[i];
                        final color = inTable.contains(c.name)
                            ? _colorOf(c.name)
                            : null;
                        return ListTile(
                          dense: true,
                          leading: Container(
                            width: 40,
                            height: 40,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: color?.withValues(alpha: .14),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: (color ?? Colors.black26).withValues(
                                  alpha: .4,
                                ),
                              ),
                            ),
                            child: Text(
                              '${i + 1}',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: color ?? Colors.black54,
                              ),
                            ),
                          ),
                          title: Text(
                            c.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          subtitle: Text(
                            '${c.seq}\n${c.category} · ${c.credit}学分'
                            ' · ${c.teacher}'
                            '${c.teachClass.isEmpty ? '' : ' · ${c.teachClass}'}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          isThreeLine: true,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    _scheduleHorizontalClamp();
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _spans.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_error!, textAlign: TextAlign.center),
            ),
            FilledButton.tonal(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }

    final s = TimetableSettings.instance;
    final days = s.visibleDays;
    const dayNames = ['一', '二', '三', '四', '五', '六', '日'];
    final today = DateTime.now();
    final todayWd = today.weekday;
    final todayIdx = days.indexOf(todayWd);
    // "进行中/下节课"只在看到真实本周（或全部视图）时生效
    final realW = _realWeek;
    final isCurrentWeekView =
        (_week == 0 && realW != null) || (_week >= 1 && _week == realW);

    // 今天各节次的进行中/下节课探测（有课的节才标记）
    var inProgressUnit = -1;
    var nextUnit = -1;
    if (isCurrentWeekView && todayIdx >= 0) {
      final nowMinutes = today.hour * 60 + today.minute;
      final covered = <int>{};
      for (final c in _spans.where((c) => c.weekday == todayWd)) {
        if (_week >= 1 && _stateOf(c) != _SpanState.active) continue;
        // 全部周视图：按真实教学周过滤，别把别的周的课算成"今天要上"
        if (_week <= 0 &&
            realW != null &&
            c.weekSet.isNotEmpty &&
            !c.weekSet.contains(realW)) {
          continue;
        }
        for (var u = c.startUnit; u <= c.endUnit; u++) {
          covered.add(u);
        }
      }
      for (final u in _displayUnits) {
        final t = PeriodTimesStore.instance.of(u <= 3 ? u + 1 : u - 1);
        if (t == null) continue;
        if (nowMinutes >= t.startMinutes && nowMinutes < t.endMinutes) {
          if (covered.contains(u)) inProgressUnit = u;
        } else if (inProgressUnit == -1 &&
            nextUnit == -1 &&
            nowMinutes < t.startMinutes &&
            covered.contains(u)) {
          nextUnit = u;
        }
      }
    }

    return Column(
      children: [
        // 顶部两行（学年学期 + 教学周）可收起：AppBar 按钮，仅课表页有
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: _headerCollapsed
              ? const SizedBox(width: double.infinity)
              : Column(
                  children: [
                    // 第一行：学年学期 + 查看全部课程
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: _semesters.length > 1
                                ? DropdownButtonFormField<String>(
                                    key: ValueKey(_semId),
                                    initialValue: _semId,
                                    decoration: const InputDecoration(
                                      labelText: '学年学期',
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                    isExpanded: true,
                                    items: _semesters
                                        .map(
                                          (s) => DropdownMenuItem(
                                            value: s.id,
                                            child: Text(
                                              s.name,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        )
                                        .toList(),
                                    onChanged: (v) =>
                                        v == null ? null : _switchSemester(v),
                                  )
                                : Text(
                                    _semName ?? '当前学期',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                    ),
                                  ),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: _showAllCourses,
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                            ),
                            child: const Text(
                              '查看全部课程',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    // 第二行：◀ | 教学周 | ▶
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: _week > 0
                                ? () => _setWeek(_week - 1)
                                : null,
                            icon: const Icon(Icons.chevron_left),
                          ),
                          Expanded(
                            child: DropdownButtonFormField<int>(
                              key: const ValueKey('week'),
                              initialValue: _week,
                              decoration: const InputDecoration(
                                labelText: '教学周',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              isExpanded: true,
                              items: [
                                const DropdownMenuItem(
                                  value: 0,
                                  child: Text('全部'),
                                ),
                                for (var w = 1; w <= 20; w++)
                                  DropdownMenuItem(
                                    value: w,
                                    child: Text('第$w周'),
                                  ),
                              ],
                              onChanged: (v) => _setWeek(v ?? 0),
                            ),
                          ),
                          IconButton(
                            onPressed: _week < 20
                                ? () => _setWeek(_week + 1)
                                : null,
                            icon: const Icon(Icons.chevron_right),
                          ),
                          // 回到当前学期 + 当前教学周：已就位时置灰
                          IconButton(
                            tooltip: '回到本周',
                            onPressed: _canBackToCurrent
                                ? _backToCurrent
                                : null,
                            icon: const Icon(Icons.today),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
        // 离线提示条：刷新失败但缓存兜底成功时
        if (_stale)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Row(
              children: [
                const Icon(Icons.cloud_off, size: 13, color: Colors.black38),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _cacheAt != null
                        ? '刷新失败，显示 ${_fmtTime(_cacheAt!)} 的缓存'
                        : '刷新失败，显示最近一次成功的数据',
                    style: const TextStyle(fontSize: 11, color: Colors.black45),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        // 下节课提示条（仅当前周视图、今天还有没上的课）
        if (nextUnit != -1)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Builder(
                builder: (_) {
                  final u = nextUnit;
                  final n = u <= 3 ? u + 1 : u - 1;
                  final t = PeriodTimesStore.instance.of(n)!;
                  CourseSpan? course;
                  for (final c in _spans.where((c) => c.weekday == todayWd)) {
                    if (_week >= 1 && _stateOf(c) != _SpanState.active) {
                      continue;
                    }
                    if (c.startUnit <= u && c.endUnit >= u) {
                      course = c;
                      break;
                    }
                  }
                  final left =
                      t.startMinutes - (today.hour * 60 + today.minute);
                  return Text(
                    '下节课：${course?.name ?? ''} · 第$n节 '
                    '${formatMinutes(t.startMinutes)}（还有 $left 分钟）',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF1A56B0),
                    ),
                  );
                },
              ),
            ),
          ),
        // 表格：表头纵向固定 + 横向同步；单一纵向 viewport，时间栏内嵌其中
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              const labelW = 46.0, minColW = 90.0, headH = 36.0;
              final rowH = s.rowHeight;
              final dayCount = days.length;
              final availW = constraints.maxWidth - labelW;
              // 塞满屏幕：列宽 = 可用宽/列数（可能很窄，不滚动）；
              // 否则保最小列宽、横向滚动
              final colW = s.fitWidth
                  ? availW / dayCount
                  : (availW / dayCount >= minColW
                        ? availW / dayCount
                        : minColW);
              final tableW = colW * dayCount;
              final gridH = rowH * _displayUnits.length;

              // 星期表头下的日期：优先锚点推算，无锚点退回相对当前周偏移
              final dayDates = List<String?>.filled(dayCount, null);
              if (_week >= 1) {
                DateTime? monday;
                if (_anchor != null) {
                  monday = _anchor!.add(Duration(days: (_week - 1) * 7));
                } else if (_curWeek != null) {
                  final now = DateTime.now();
                  monday = now
                      .subtract(Duration(days: now.weekday - 1))
                      .add(Duration(days: (_week - _curWeek!) * 7));
                }
                if (monday != null) {
                  for (var i = 0; i < dayCount; i++) {
                    final date = monday.add(Duration(days: days[i] - 1));
                    dayDates[i] = '${date.month}/${date.day}';
                  }
                }
              }

              return Column(
                children: [
                  // 表头：左角格（纵向固定）+ 横向滚动的星期行
                  Container(
                    height: headH,
                    color: const Color(0xFFF2F4F8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: labelW, child: _cornerCell('节次')),
                        Expanded(
                          child: SingleChildScrollView(
                            controller: _headHCtrl,
                            scrollDirection: Axis.horizontal,
                            child: SizedBox(
                              width: tableW,
                              height: headH,
                              child: Row(
                                children: [
                                  for (var i = 0; i < dayCount; i++)
                                    SizedBox(
                                      width: colW,
                                      height: headH,
                                      child: Container(
                                        // 今日列高亮
                                        color: i == todayIdx
                                            ? const Color(0x141A56B0)
                                            : null,
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              '周${dayNames[days[i] - 1]}',
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 12,
                                                color: i == todayIdx
                                                    ? const Color(0xFF1A56B0)
                                                    : null,
                                              ),
                                            ),
                                            if (dayDates[i] != null)
                                              Text(
                                                dayDates[i]!,
                                                style: TextStyle(
                                                  fontSize: 9,
                                                  color: i == todayIdx
                                                      ? const Color(0xCC1A56B0)
                                                      : Colors.black45,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 表体：纵向滚动 Row[时间栏 | 横向滚动的日列]，
                  // 时间栏和课格在同一个 viewport 里，纵向天然对齐
                  Expanded(
                    child: SingleChildScrollView(
                      child: SizedBox(
                        height: gridH,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: labelW,
                              child: Column(
                                children: [
                                  for (final u in _displayUnits)
                                    _railCell(
                                      '第${u <= 3 ? u + 1 : u - 1}节',
                                      height: rowH,
                                      time: s.showRailTimes
                                          ? PeriodTimesStore.instance.of(
                                              u <= 3 ? u + 1 : u - 1,
                                            )
                                          : null,
                                      highlight:
                                          isCurrentWeekView &&
                                          todayIdx >= 0 &&
                                          inProgressUnit == u,
                                    ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: SingleChildScrollView(
                                controller: _bodyHCtrl,
                                scrollDirection: Axis.horizontal,
                                child: SizedBox(
                                  width: tableW,
                                  height: gridH,
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      for (var i = 0; i < dayCount; i++)
                                        _dayColumn(
                                          days[i],
                                          colW,
                                          rowH,
                                          isToday: i == todayIdx,
                                          inProgressUnit: isCurrentWeekView
                                              ? inProgressUnit
                                              : -1,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  /// 跨两个及以上显示行的卡算高卡，课名多给几行
  bool _isTall(CourseSpan s) {
    final top = _rowOf(s.startUnit).clamp(0, _displayUnits.length - 1);
    final end = _rowOf(s.endUnit).clamp(top, _displayUnits.length - 1);
    return end > top;
  }

  /// 一天的列：节次横线 + 该天所有课卡（Stack 绝对定位）。
  /// isToday 列微染底色，进行中的节次行加边框强调
  Widget _dayColumn(
    int d,
    double colW,
    double rowH, {
    required bool isToday,
    required int inProgressUnit,
  }) {
    var daySpans = _spans.where((c) => c.weekday == d).toList();
    // 关掉"显示非本周课程"时，选中具体周的视图里只留本周在上的课
    if (!TimetableSettings.instance.showNonCurrentWeek && _week >= 1) {
      daySpans = daySpans
          .where((c) => _stateOf(c) == _SpanState.active)
          .toList();
    }
    final groups = _overlapGroups(daySpans);
    return SizedBox(
      width: colW,
      height: rowH * _displayUnits.length,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          for (var i = 0; i < _displayUnits.length; i++)
            Positioned(
              top: i * rowH,
              left: 0,
              right: 0,
              height: rowH,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: isToday
                      ? (inProgressUnit == _displayUnits[i]
                            ? const Color(0x0F1A56B0)
                            : const Color(0x051A56B0))
                      : null,
                  border: Border(
                    top: BorderSide(
                      color: isToday && inProgressUnit == _displayUnits[i]
                          ? const Color(0x661A56B0)
                          : Colors.black12,
                      width: .5,
                    ),
                  ),
                ),
              ),
            ),
          for (final g in groups) ..._groupCard(g, rowH),
        ],
      ),
    );
  }

  Positioned _positionedCard(Widget card, CourseSpan s, double rowH) {
    final topRow = _rowOf(s.startUnit).clamp(0, _displayUnits.length - 1);
    final endRow = _rowOf(s.endUnit).clamp(topRow, _displayUnits.length - 1);
    return Positioned(
      top: topRow * rowH,
      left: 0,
      right: 0,
      height: (endRow - topRow + 1) * rowH,
      child: card,
    );
  }

  /// 重叠组唯一的渲染路径（返回该组的全部 Positioned 子节点）：
  /// 组内按展示顺序选中一张全浓度课卡，多于一门时右下角角标提示、
  /// 点击轮换（带淡入动效）；其余成员画无文字淡色底块露出形状——
  /// 与选中卡同格的底块会被完全遮住还会透字，跳过不画
  List<Widget> _groupCard(List<CourseSpan> g, double rowH) {
    // 展示顺序：本周在上的课优先（轮换默认落在实际有课的那张），
    // 同状态内再按时长、晚开始
    int rank(CourseSpan c) => _stateOf(c) == _SpanState.active ? 0 : 1;
    final sorted = [...g]
      ..sort((a, b) {
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : _compareDisplay(a, b);
      });
    final key = '${g.first.weekday}:${g.first.startUnit}:${g.first.endUnit}';
    final pick = (_conflictPick[key] ?? 0) % sorted.length;
    final shown = sorted[pick];
    final multi = sorted.length > 1;
    final shownTop = _rowOf(shown.startUnit).clamp(0, _displayUnits.length - 1);
    final shownEnd = _rowOf(
      shown.endUnit,
    ).clamp(shownTop, _displayUnits.length - 1);

    Widget card = Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned.fill(
          // 切换课程时的淡入 + 轻微上移动效。
          // layoutBuilder 必须用 StackFit.expand：默认的 loose Stack 会把
          // 卡片收缩成内容高度再居中，不再撑满选中区
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeIn,
            layoutBuilder: (currentChild, previousChildren) => Stack(
              fit: StackFit.expand,
              alignment: Alignment.center,
              children: [...previousChildren, ?currentChild],
            ),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, .06),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: _spanCard(
              shown,
              tall: _isTall(shown),
              key: ValueKey('$pick:${shown.name}:${shown.startUnit}'),
            ),
          ),
        ),
        if (multi)
          Positioned(
            right: 5,
            bottom: 5,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .06),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Icon(
                Icons.layers_outlined,
                size: 12,
                color: Colors.black54,
              ),
            ),
          ),
      ],
    );
    if (multi) {
      card = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _conflictPick[key] = pick + 1),
        child: card,
      );
    }
    return [
      for (final s in g)
        if (s != shown && !_sameDisplayRect(s, shownTop, shownEnd))
          _positionedCard(_ghostCard(s), s, rowH),
      _positionedCard(card, shown, rowH),
    ];
  }

  /// s 的显示行区间是否与选中卡 [top, end] 完全同格
  bool _sameDisplayRect(CourseSpan s, int top, int end) {
    final t = _rowOf(s.startUnit).clamp(0, _displayUnits.length - 1);
    final e = _rowOf(s.endUnit).clamp(t, _displayUnits.length - 1);
    return t == top && e == end;
  }

  /// 组内未选中成员的底块：无文字，按课程色露出形状；
  /// 三态同样生效（未开始/已结课更淡，已结课转灰）；长按同样弹详情
  Widget _ghostCard(CourseSpan c) {
    final st = _stateOf(c);
    final bg = st == _SpanState.pastEnded ? Colors.black : _colorOf(c.name);
    final alpha = st == _SpanState.active ? .10 : .05;
    return GestureDetector(
      onLongPress: () => _showCourseDetails(c),
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: bg.withValues(alpha: alpha),
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    );
  }

  /// 课卡：按三态上色；高卡（跨多行）多给课名行数；
  /// 未开始/已结课在卡片底部中央加标注。
  /// 显示内容（教室/老师/周次角标）与水平/垂直居中走显示设置；
  /// 长按弹详情
  Widget _spanCard(CourseSpan c, {required bool tall, Key? key}) {
    final st = _stateOf(c);
    final hue = _colorOf(c.name);
    final settings = TimetableSettings.instance;
    final Color bg;
    final double bgAlpha;
    final double borderAlpha;
    final Color textColor;
    switch (st) {
      case _SpanState.active:
        bg = hue;
        bgAlpha = .14;
        borderAlpha = .5;
        textColor = Colors.black87;
      case _SpanState.futureInactive:
        bg = hue; // 淡彩：还没上，保留颜色暗示
        bgAlpha = .05;
        borderAlpha = .25;
        textColor = Colors.black38;
      case _SpanState.pastEnded:
        bg = Colors.black; // 灰：已经结了
        bgAlpha = .04;
        borderAlpha = .18;
        textColor = Colors.black38;
    }
    return GestureDetector(
      onLongPress: () => _showCourseDetails(c),
      child: Container(
        key: key,
        margin: const EdgeInsets.all(2),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: bg.withValues(alpha: bgAlpha),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: bg.withValues(alpha: borderAlpha)),
        ),
        child: Stack(
          alignment: Alignment(
            settings.cardCenterH ? 0 : -1,
            settings.cardCenterV ? 0 : -1,
          ),
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: settings.cardCenterH
                  ? CrossAxisAlignment.center
                  : CrossAxisAlignment.start,
              children: [
                Flexible(
                  child: Text(
                    c.name,
                    softWrap: true,
                    maxLines: tall ? 6 : 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: settings.cardCenterH
                        ? TextAlign.center
                        : TextAlign.start,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.bold,
                      color: textColor,
                    ),
                  ),
                ),
                if (settings.cardShowRoom && c.room.isNotEmpty)
                  Text(
                    c.room,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9.5,
                      color: textColor.withValues(alpha: .85),
                    ),
                  ),
                if (settings.cardShowTeacher && c.teacher.isNotEmpty)
                  Text(
                    c.teacher,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9,
                      color: textColor.withValues(alpha: .75),
                    ),
                  ),
                if (settings.cardShowWeeksTag &&
                    _week == 0 &&
                    c.weeks.isNotEmpty)
                  Text(
                    '${c.weeks}周',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9,
                      color: textColor.withValues(alpha: .7),
                    ),
                  ),
              ],
            ),
            // 底部中央的状态标注（仅未开始/已结课）
            if (st != _SpanState.active)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: bg.withValues(alpha: math.min(.14, bgAlpha + .07)),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      st == _SpanState.futureInactive ? '未开始' : '已结课',
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 8,
                        height: 1.2,
                        color: textColor,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 长按课卡详情：全部静态信息一屏看全
  void _showCourseDetails(CourseSpan c) {
    final times = PeriodTimesStore.instance;
    final p1 = unitToPeriod(c.startUnit);
    final p2 = unitToPeriod(c.endUnit);
    final t1 = (p1 == null || p1 > times.times.length) ? null : times.of(p1);
    final t2 = (p2 == null || p2 > times.times.length) ? null : times.of(p2);
    final st = _stateOf(c);
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.black45),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13.5))),
        ],
      ),
    );
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                c.name,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              if (c.teacher.isNotEmpty) row('老师', c.teacher),
              if (c.room.isNotEmpty) row('教室', c.room),
              row('星期', '周${'一二三四五六日'[c.weekday - 1]}'),
              if (p1 != null)
                row('节次', p2 == null || p2 == p1 ? '第$p1节' : '第$p1 - $p2节'),
              if (t1 != null && t2 != null)
                row(
                  '时间',
                  '${formatMinutes(t1.startMinutes)} - '
                      '${formatMinutes(t2.endMinutes)}',
                ),
              if (c.weeks.isNotEmpty)
                row('周次', c.weekSet.isEmpty ? c.weeks : '第 ${c.weeks} 周'),
              if (_week >= 1)
                row('本周', switch (st) {
                  _SpanState.active => '在上',
                  _SpanState.futureInactive => '未开始',
                  _SpanState.pastEnded => '已结课',
                }),
              if (_week >= 1 && _anchor != null)
                row(
                  '日期',
                  _fmtDate(
                    _anchor!.add(
                      Duration(days: (_week - 1) * 7 + c.weekday - 1),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmtTime(DateTime t) =>
      '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}'
      ' ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Widget _cornerCell(String t) => Container(
    height: 36,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: const Color(0xFFF2F4F8),
      border: Border.all(color: Colors.black12, width: 0.5),
    ),
    child: Text(
      t,
      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
    ),
  );

  /// 时间栏格：节号 + 上下课时刻（开关控制）；行高跟随设置
  Widget _railCell(
    String t, {
    required double height,
    PeriodTime? time,
    bool highlight = false,
  }) => Container(
    height: height,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: highlight ? const Color(0x0F1A56B0) : null,
      border: Border(
        right: const BorderSide(color: Colors.black12),
        bottom: BorderSide(
          color: highlight ? const Color(0x661A56B0) : Colors.black12,
        ),
      ),
    ),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(t, style: const TextStyle(fontSize: 11, color: Colors.black54)),
        if (time != null) ...[
          const SizedBox(height: 2),
          Text(
            formatMinutes(time.startMinutes),
            style: const TextStyle(fontSize: 8.5, color: Colors.black45),
          ),
          Text(
            formatMinutes(time.endMinutes),
            style: const TextStyle(
              fontSize: 8.5,
              height: 1.15,
              color: Colors.black45,
            ),
          ),
        ],
      ],
    ),
  );

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
