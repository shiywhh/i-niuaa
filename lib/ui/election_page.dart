// Engine | Flutter 3.x / Dart 3 | lib/ui/election_page.dart
// 选课：学期选课（Xuanke_v2 同款抢课链路：档案 ID → 课程目录 → 定时/立即提交 + 日志）
//      + 补选/重修目录（可搜索）+ 未中选
// 提交：stdElectCourse!batchOperator.action?…（optype=true, operator0={id}:true:0, lesson0={id}）
//       预发射倒计时、主备参数轮换、限速退避、每课重试，判定口径与 Xuanke_v2 一致

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/current_semester.dart';
import '../core/eams_client.dart';
import '../core/models.dart';
import '../core/session.dart';

class ElectionsPage extends StatelessWidget {
  const ElectionsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.surface,
            child: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              dividerColor: Colors.black12,
              labelColor: Theme.of(context).colorScheme.primary,
              unselectedLabelColor: Colors.black54,
              indicatorColor: Theme.of(context).colorScheme.primary,
              tabs: const [
                Tab(text: '学期选课'),
                Tab(text: '补选/重修'),
                Tab(text: '未中选'),
              ],
            ),
          ),
          const Expanded(
            child: TabBarView(
              children: [
                ElectGrabScreen(),
                ElectCatalogScreen(),
                ElectBinScreen(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// 学期选课：选课视图 → 抢课控制台
// ============================================================

const _cGreen = Color(0xFF2E7D32);
const _cRed = Color(0xFFC62828);
const _cAmber = Color(0xFFB8860B);
const _cGray = Colors.black54;

class _LogLine {
  final DateTime ts;
  final String msg;
  final Color color;
  _LogLine(this.ts, this.msg, this.color);
}

class ElectGrabScreen extends StatefulWidget {
  const ElectGrabScreen({super.key});

  @override
  State<ElectGrabScreen> createState() => _ElectGrabScreenState();
}

class _ElectGrabScreenState extends State<ElectGrabScreen> {
  final _pidCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  final _logCtrl = ScrollController();

  String _pid = ''; // 获取课程时校验过的档案 ID
  String? _usedParam;
  List<ElectLesson> _lessons = const [];
  final _checked = <String>{};
  bool _fetching = false;
  String? _error;
  String? _hint;
  bool _onConsole = false;

  // 运行态
  bool _running = false;
  bool _stop = false;
  late DateTime _target;
  int _prefireMs = 200;
  int _intervalMs = 800;
  int _maxAttempts = 3;
  String _countdown = '--:--:--.---';
  int _submitted = 0, _ok = 0, _failed = 0;
  final _logs = <_LogLine>[];

  @override
  void initState() {
    super.initState();
    final saved = Session.I.prefs.getString('elect.lastPid');
    if (saved != null && saved.isNotEmpty) _pidCtrl.text = saved;
    final now = DateTime.now();
    _target = DateTime(now.year, now.month, now.day + 1, 9); // 默认明天 09:00
    _searchCtrl.addListener(() => setState(() {}));
    _autodetect();
  }

  @override
  void dispose() {
    _pidCtrl.dispose();
    _searchCtrl.dispose();
    _logCtrl.dispose();
    super.dispose();
  }

  String get _query => _searchCtrl.text.trim().toLowerCase();

  List<ElectLesson> get _visible {
    final q = _query;
    if (q.isEmpty) return _lessons;
    return _lessons
        .where(
          (c) =>
              c.name.toLowerCase().contains(q) ||
              c.id.contains(q) ||
              c.code.toLowerCase().contains(q) ||
              c.teachers.toLowerCase().contains(q),
        )
        .toList();
  }

  // ── 档案 ID 自动识别 ──
  Future<void> _autodetect() async {
    try {
      final ids = await Session.I.guard(Session.I.eams.electProfileIds);
      if (!mounted || ids.isEmpty) return;
      setState(() {
        if (_pidCtrl.text.trim().isEmpty) _pidCtrl.text = ids.first;
        _hint = '自动识别到档案 ID：${ids.join(' / ')}';
      });
    } catch (_) {}
  }

  // ── 获取课程目录 ──
  Future<void> _fetchLessons() async {
    final pid = _pidCtrl.text.trim();
    if (!RegExp(r'^\d+$').hasMatch(pid)) {
      _toast('请输入有效的选课档案 ID（纯数字）');
      return;
    }
    setState(() {
      _fetching = true;
      _error = null;
    });
    try {
      final (lessons, realPid, param) = await Session.I.guard(
        () => Session.I.eams.electLessons(pid),
      );
      await Session.I.prefs.setString('elect.lastPid', realPid);
      if (!mounted) return;
      setState(() {
        _lessons = lessons;
        _pid = realPid;
        _usedParam = param;
        _checked.clear();
        _fetching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _fetching = false;
      });
    }
  }

  // ── 抢课主流程（Xuanke_v2 GrabWorker 的移植）──
  Future<void> _start({required bool timed}) async {
    if (_running) return;
    if (_checked.isEmpty) {
      _toast('请至少选择一门课程');
      return;
    }
    var target = _target;
    if (timed && target.isBefore(DateTime.now())) {
      if (!await _confirm('目标时间已过，将立即开始提交。确定继续？')) return;
      target = DateTime.now().add(const Duration(seconds: 1));
      setState(() => _target = target);
    }
    if (!timed && !await _confirm('将立即提交 ${_checked.length} 门课程，确定？')) {
      return;
    }

    final fire = timed
        ? target.subtract(Duration(milliseconds: _prefireMs))
        : DateTime.now().add(const Duration(milliseconds: 500));

    setState(() {
      _running = true;
      _stop = false;
      _submitted = _ok = _failed = 0;
      _logs.clear();
      _onConsole = true;
    });
    _log('⏳ 目标发射 ${_fmtTs(fire)}（含预发射折算）', _cGray);
    _log('📦 待抢课程 ${_checked.length} 门 | 档案 $_pid | 参数 $_usedParam', _cGray);

    // 预热（服务端把档案写进会话）
    try {
      await Session.I.guard(() => Session.I.eams.warmElect(_pid));
    } catch (_) {}

    // 倒计时阶段
    while (!_stop) {
      final remain = fire.difference(DateTime.now());
      if (remain.isNegative) break;
      if (!mounted) return;
      setState(() => _countdown = _fmtDur(remain));
      await Future.delayed(
        remain > const Duration(seconds: 1)
            ? const Duration(milliseconds: 100)
            : const Duration(milliseconds: 10),
      );
    }
    if (!mounted) return;
    if (_stop) {
      _log('⚠️ 用户停止了抢课', _cAmber);
      _finish();
      return;
    }
    setState(() => _countdown = '🔥 发射！');

    final cids = _checked.toList();
    final params = _usedParam == 'profileId'
        ? const ['profileId', 'electionProfile.id']
        : const ['electionProfile.id', 'profileId'];
    var lastPost = DateTime.fromMillisecondsSinceEpoch(0);

    for (var i = 0; i < cids.length; i++) {
      if (_stop) break;
      final cid = cids[i];
      _log('→ (${i + 1}/${cids.length}) 正在提交课程 $cid', _cGray);

      var sentOk = false;
      for (
        var attempt = 1;
        attempt <= _maxAttempts && !sentOk && !_stop;
        attempt++
      ) {
        for (final param in params) {
          if (_stop) break;

          // 限速：与上次提交保持最小间隔
          final gap = DateTime.now().difference(lastPost);
          final minGap = Duration(milliseconds: _intervalMs);
          if (gap < minGap) await Future.delayed(minGap - gap);
          lastPost = DateTime.now();

          try {
            final r = await Session.I.guard(
              () => Session.I.eams.electSubmitOnce(
                _pid,
                param: param,
                courseId: cid,
              ),
            );
            if (!mounted) return;
            setState(() => _submitted++);
            final ts = _fmtTs(DateTime.now());
            if (r.verdict == ElectVerdict.ok) {
              _log('[$ts] ✅ ${r.status} → ${r.message}', _cGreen);
              setState(() => _ok++);
              sentOk = true;
            } else if (r.verdict == ElectVerdict.rateLimited) {
              _log('[$ts] ⚠️ ${r.status} → ${r.message}（退避 3s）', _cAmber);
              setState(() => _failed++);
              await Future.delayed(const Duration(seconds: 3));
            } else if (r.verdict == ElectVerdict.fail) {
              _log('[$ts] ❌ ${r.status} → ${r.message}', _cRed);
              setState(() => _failed++);
            } else {
              // 无明确成败字样：与 Xuanke_v2 一致，按已提交处理，不再重试
              _log('[$ts] ⚪ ${r.status} → ${r.message}', _cGray);
              sentOk = true;
            }
          } on SessionExpired {
            _log('💥 会话失效且重登未成功，终止抢课', _cRed);
            setState(() => _failed++);
            _stop = true;
            break;
          } catch (e) {
            if (!mounted) return;
            setState(() => _failed++);
            _log('💥 网络异常 → $e', _cRed);
          }
        }
      }
      if (!sentOk && !_stop) _log('⚠️ 课程 $cid：$_maxAttempts 次尝试均未成功', _cAmber);
    }

    _log(
      '🏁 抢课结束 | 提交: $_submitted | 成功: $_ok | 失败: $_failed',
      _ok > 0 ? _cGreen : _cGray,
    );
    _finish();
  }

  void _stopJob() => _stop = true;

  void _finish() {
    if (!mounted) return;
    setState(() {
      _running = false;
      _stop = false;
      _countdown = '--:--:--.---';
    });
  }

  void _log(String msg, Color color) {
    if (!mounted) return;
    setState(() => _logs.add(_LogLine(DateTime.now(), msg, color)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logCtrl.hasClients) {
        _logCtrl.jumpTo(_logCtrl.position.maxScrollExtent);
      }
    });
  }

  // ── 小工具 ──
  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<bool> _confirm(String msg) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('确认'),
        content: Text(msg),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return r == true;
  }

  Future<void> _pickTarget() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _target,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_target),
    );
    if (!mounted) return;
    setState(() {
      _target = t == null
          ? DateTime(d.year, d.month, d.day, 9)
          : DateTime(d.year, d.month, d.day, t.hour, t.minute);
    });
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _fmtTs(DateTime t) =>
      '${t.year}-${_two(t.month)}-${_two(t.day)} '
      '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

  static String _fmtDur(Duration d) {
    final ms = d.inMilliseconds;
    return '${_two(ms ~/ 3600000)}:'
        '${_two((ms % 3600000) ~/ 60000)}:'
        '${_two((ms % 60000) ~/ 1000)}.'
        '${(ms % 1000).toString().padLeft(3, '0')}';
  }

  // ── UI ──
  @override
  Widget build(BuildContext context) {
    return _onConsole ? _buildConsole() : _buildPicker();
  }

  Widget _buildPicker() {
    final visible = _visible;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _pidCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: '选课档案 ID',
                    hintText: '如 4665',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              IconButton(
                tooltip: '自动识别档案 ID',
                onPressed: _fetching ? null : _autodetect,
                icon: const Icon(Icons.auto_awesome),
              ),
            ],
          ),
        ),
        if (_hint != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _hint!,
                style: const TextStyle(fontSize: 11, color: Colors.black45),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _fetching ? null : _fetchLessons,
              icon: const Icon(Icons.download),
              label: Text(_fetching ? '获取中...' : '获取课程列表'),
            ),
          ),
        ),
        if (_fetching) const LinearProgressIndicator(),
        if (_error != null)
          Expanded(child: _retry(_error!, _fetchLessons))
        else if (_lessons.isEmpty)
          const Expanded(
            child: Center(
              child: Text(
                '输入档案 ID 后获取课程列表',
                style: TextStyle(color: Colors.black45),
              ),
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                hintText: '搜索课程名 / ID / 教师',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            child: Row(
              children: [
                TextButton(
                  onPressed: () => _setAll(true),
                  child: const Text('全选'),
                ),
                TextButton(
                  onPressed: () => _setAll(false),
                  child: const Text('取消'),
                ),
                TextButton(onPressed: _invert, child: const Text('反选')),
                const Spacer(),
                Text(
                  '已选 ${_checked.length} / ${_lessons.length} 门',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: visible.isEmpty
                ? const Center(
                    child: Text(
                      '没有匹配的课程',
                      style: TextStyle(color: Colors.black45),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    itemCount: visible.length,
                    itemBuilder: (_, i) {
                      final c = visible[i];
                      final sub = [
                        'ID ${c.id}',
                        if (c.code.isNotEmpty) c.code,
                        if (c.teachers.isNotEmpty) c.teachers,
                      ].join(' · ');
                      return CheckboxListTile(
                        value: _checked.contains(c.id),
                        onChanged: (v) => setState(
                          () => v == true
                              ? _checked.add(c.id)
                              : _checked.remove(c.id),
                        ),
                        dense: true,
                        title: Text(
                          c.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        subtitle: Text(
                          sub,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.black54,
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _checked.isEmpty
                      ? null
                      : () => setState(() => _onConsole = true),
                  icon: const Icon(Icons.rocket_launch),
                  label: Text('✅ 确认选择，进入提交（${_checked.length} 门）'),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  void _setAll(bool checked) {
    setState(() {
      for (final c in _visible) {
        checked ? _checked.add(c.id) : _checked.remove(c.id);
      }
    });
  }

  void _invert() {
    setState(() {
      for (final c in _visible) {
        _checked.contains(c.id) ? _checked.remove(c.id) : _checked.add(c.id);
      }
    });
  }

  Widget _buildConsole() {
    return Column(
      children: [
        Card(
          margin: const EdgeInsets.fromLTRB(10, 10, 10, 0),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '📌 已选 ${_checked.length} 门 | 档案 $_pid | 参数 $_usedParam',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _running
                      ? null
                      : () => setState(() => _onConsole = false),
                  child: const Text('重新选课'),
                ),
              ],
            ),
          ),
        ),
        Card(
          margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Column(
              children: [
                InkWell(
                  onTap: _running ? null : _pickTarget,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.schedule, size: 18),
                        const SizedBox(width: 8),
                        const Text(
                          '目标时间',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          _fmtTs(_target),
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        const Icon(Icons.arrow_drop_down),
                      ],
                    ),
                  ),
                ),
                Row(
                  children: [
                    _strategyDropdown<int>(
                      label: '预发射',
                      value: _prefireMs,
                      items: const [100, 200, 300, 500, 1000],
                      suffix: 'ms',
                      onChanged: _running
                          ? null
                          : (v) => setState(() => _prefireMs = v ?? 200),
                    ),
                    const SizedBox(width: 8),
                    _strategyDropdown<int>(
                      label: '间隔',
                      value: _intervalMs,
                      items: const [500, 800, 1000, 1500, 2000],
                      suffix: 'ms',
                      onChanged: _running
                          ? null
                          : (v) => setState(() => _intervalMs = v ?? 800),
                    ),
                    const SizedBox(width: 8),
                    _strategyDropdown<int>(
                      label: '每课尝试',
                      value: _maxAttempts,
                      items: const [1, 2, 3, 5, 8, 10],
                      suffix: '次',
                      onChanged: _running
                          ? null
                          : (v) => setState(() => _maxAttempts = v ?? 3),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            _countdown,
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.bold,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: _running
                  ? Theme.of(context).colorScheme.primary
                  : Colors.black38,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: _running
                        ? _cRed
                        : Theme.of(context).colorScheme.primary,
                  ),
                  onPressed: _running ? _stopJob : () => _start(timed: true),
                  icon: Icon(_running ? Icons.stop : Icons.play_arrow),
                  label: Text(_running ? '⏹ 停止抢课' : '▶ 开始抢课'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _running ? null : () => _start(timed: false),
                  icon: const Icon(Icons.bolt),
                  label: const Text('⚡ 立即提交'),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Text(
                '提交 $_submitted',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                '成功 $_ok',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: _cGreen,
                ),
              ),
              Text(
                '失败 $_failed',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: _cRed,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _logs.isEmpty
              ? const Center(
                  child: Text('等待开始…', style: TextStyle(color: Colors.black38)),
                )
              : ListView.builder(
                  controller: _logCtrl,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  itemCount: _logs.length,
                  itemBuilder: (_, i) {
                    final l = _logs[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${_two(l.ts.hour)}:${_two(l.ts.minute)}:'
                            '${_two(l.ts.second)} ',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.black38,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                          Expanded(
                            child: Text(
                              l.msg,
                              style: TextStyle(fontSize: 12, color: l.color),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _strategyDropdown<T>({
    required String label,
    required T value,
    required List<T> items,
    required String suffix,
    required ValueChanged<T?>? onChanged,
  }) {
    return Expanded(
      child: DropdownButtonFormField<T>(
        initialValue: value,
        onChanged: onChanged,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 6,
          ),
        ),
        items: items
            .map(
              (v) => DropdownMenuItem(
                value: v,
                child: Text('$v$suffix', style: const TextStyle(fontSize: 12)),
              ),
            )
            .toList(),
      ),
    );
  }
}

// ============================================================
// 补选/重修：全部通选课目录 + 搜索
// ============================================================

class ElectCatalogScreen extends StatefulWidget {
  const ElectCatalogScreen({super.key});

  @override
  State<ElectCatalogScreen> createState() => _ElectCatalogScreenState();
}

class _ElectCatalogScreenState extends State<ElectCatalogScreen> {
  List<ElectiveCourse>? _courses;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final c = await Session.I.guard(Session.I.eams.electCatalog);
      setState(() => _courses = c);
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final courses = _courses;
    if (_error != null) return _retry(_error!, _load);
    if (courses == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final q = _query.trim();
    final filtered = q.isEmpty
        ? courses
        : courses
              .where(
                (c) =>
                    c.name.contains(q) ||
                    c.teachers.contains(q) ||
                    c.no.contains(q) ||
                    c.courseTypeName.contains(q),
              )
              .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            decoration: const InputDecoration(
              hintText: '搜索课程名 / 教师 / 课程序号 / 类别',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '共 ${filtered.length} 门',
              style: const TextStyle(fontSize: 12, color: Colors.black45),
            ),
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? const Center(child: Text('没有匹配的课程'))
              : ListView.builder(
                  padding: const EdgeInsets.all(10),
                  itemCount: filtered.length,
                  itemBuilder: (_, i) => _card(filtered[i]),
                ),
        ),
      ],
    );
  }

  Widget _card(ElectiveCourse c) => Card(
    margin: const EdgeInsets.symmetric(vertical: 4),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  c.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${c.credits} 学分',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${c.no} · ${c.courseTypeName} · ${c.campusName}',
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
          if (c.teachers.isNotEmpty)
            Text(
              '教师：${c.teachers}',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          if (c.teachClassName.isNotEmpty)
            Text(
              c.teachClassName,
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          if (c.timeDigests.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                c.timeDigests.join('；'),
                style: const TextStyle(fontSize: 12, color: Color(0xFF0A66C2)),
              ),
            ),
          const SizedBox(height: 4),
          Text(
            '已选 ${c.stdCount} / 上限 ${c.limitCount}',
            style: TextStyle(
              fontSize: 12,
              color:
                  int.tryParse(c.stdCount) != null &&
                      int.tryParse(c.limitCount) != null &&
                      int.parse(c.stdCount) >= int.parse(c.limitCount)
                  ? Colors.red
                  : Colors.green,
            ),
          ),
        ],
      ),
    ),
  );
}

/// 未中选课程：stdCourseTakeBin!search.action 的真实网格数据
class ElectBinScreen extends StatefulWidget {
  const ElectBinScreen({super.key});

  @override
  State<ElectBinScreen> createState() => _ElectBinScreenState();
}

class _ElectBinScreenState extends State<ElectBinScreen> {
  List<CourseBinRecord>? _records;
  List<Semester> _semesters = const [];
  String? _semId; // null = 当前学期
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  /// 先拿学期列表并默认选当前学期，再查未中选
  Future<void> _init() async {
    await _loadSemesters();
    if (!mounted) return;
    // 默认选中当前学期（与课表页一致）；不在列表时回落第一项。
    // 最多等 8s：新装首启课表还没写入 tt_cur_sem
    final cur = await CurrentSemester.id(timeout: const Duration(seconds: 8));
    _semId ??= _semesters.isNotEmpty
        ? (_semesters.any((s) => s.id == cur) ? cur : _semesters.first.id)
        : null;
    await _load();
  }

  Future<void> _loadSemesters() async {
    try {
      final s = await Session.I.guard(Session.I.eams.semesters);
      if (mounted) setState(() => _semesters = s);
    } catch (_) {}
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final v = await Session.I.guard(
        () => Session.I.eams.courseTakeBin(semesterId: _semId),
      );
      if (mounted) setState(() => _records = v);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final records = _records;
    if (_error != null) return _retry(_error!, _load);
    if (records == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        if (_semesters.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: DropdownButtonFormField<String>(
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
                      child: Text(s.name, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v == null || v == _semId) return;
                setState(() => _semId = v);
                _load();
              },
            ),
          ),
        Expanded(child: _buildList(records)),
      ],
    );
  }

  Widget _buildList(List<CourseBinRecord> records) {
    if (records.isEmpty) {
      return const Center(
        child: Text('当前学期没有未中选记录', style: TextStyle(color: Colors.black45)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(10),
      itemCount: records.length,
      itemBuilder: (_, i) {
        final c = records[i];
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        c.courseName,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF3E0),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        c.status,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF8D5B00),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '${c.courseNo} · ${c.courseCode}',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
                if (c.category.isNotEmpty)
                  Text(
                    '课程类别：${c.category}',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                Text(
                  '选课方式：${c.electWay} · 轮次 ${c.round}'
                  '${c.groupNo.isEmpty ? '' : ' · 组 ${c.groupNo}'}',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
                if (c.currency.isNotEmpty)
                  Text(
                    '货币值：${c.currency}',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

Widget _retry(String msg, Future<void> Function() load) => Center(
  child: Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Padding(
        padding: const EdgeInsets.all(24),
        child: Text(msg, textAlign: TextAlign.center),
      ),
      FilledButton.tonal(onPressed: load, child: const Text('重试')),
    ],
  ),
);
