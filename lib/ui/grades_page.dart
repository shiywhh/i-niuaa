// Engine | Flutter 3.x / Dart 3 | lib/ui/grades_page.dart
// 成绩页：校方口径绩点汇总（historyCourseGradeDetail：学期 GPA / 必修 GPA /
// 在校汇总 / 学年统计）+ 全部课程明细（person-grade.action）

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/session.dart';

class GradesPage extends StatefulWidget {
  const GradesPage({super.key});

  @override
  State<GradesPage> createState() => _GradesPageState();
}

class _GradesPageState extends State<GradesPage> {
  GradeSummary? _summary;
  List<GradeEntry>? _entries;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final s = await Session.I.guard(Session.I.eams.historyGrade);
      final g = await Session.I.guard(Session.I.eams.grades);
      if (mounted) {
        setState(() {
          _summary = s;
          _entries = g;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    final entries = _entries;
    if (_error != null) return _CenterError(_error!, _load);
    if (summary == null || entries == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final overall = summary.overall;

    // 学年 → 年级（大一/大二/…）：按学年起始数字升序推，最早在读学年 = 大一
    final starts =
        summary.years.map((y) => _startYear(y.year)).whereType<int>().toList()
          ..sort();
    String gradeOf(String year) {
      final s = _startYear(year);
      final i = s == null ? -1 : starts.indexOf(s);
      if (i < 0) return year;
      return i < _gradeCn.length ? '大${_gradeCn[i]}' : '第${i + 1}年';
    }

    final bySem = <String, List<GradeEntry>>{};
    for (final e in entries) {
      (bySem[e.semester] ??= []).add(e);
    }
    final sems = bySem.keys.toList()..sort((a, b) => b.compareTo(a));

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // 校方口径总览
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _stat('GPA', overall?.gpa?.toStringAsFixed(1)),
                    _stat('必修 GPA', overall?.reqGpa?.toStringAsFixed(1)),
                    _stat(
                      '已获学分',
                      overall == null
                          ? '—'
                          : overall.credits.toStringAsFixed(1),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (overall == null)
                  Text(
                    '暂无汇总数据',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
              ],
            ),
          ),
        ),
        // 学期绩点表（校方口径）
        if (summary.semesters.isNotEmpty)
          Card(
            margin: const EdgeInsets.only(top: 4),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Column(
                children: [
                  _row(
                    ['学年学期', '门数', '总学分', 'GPA', '必修GPA'],
                    bold: true,
                    flexes: const [4, 2, 2, 2, 2],
                  ),
                  const Divider(height: 1),
                  for (final s in summary.semesters)
                    _row(
                      [
                        '${s.year} ${s.term}',
                        '${s.count}',
                        s.credits.toStringAsFixed(1),
                        s.gpa?.toStringAsFixed(1) ?? '—',
                        s.reqGpa?.toStringAsFixed(1) ?? '—',
                      ],
                      flexes: const [4, 2, 2, 2, 2],
                    ),
                ],
              ),
            ),
          ),
        // 学年统计
        if (summary.years.isNotEmpty)
          Card(
            margin: const EdgeInsets.only(top: 4),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Column(
                children: [
                  _row(
                    ['学年', '门数', '总学分', '必修学分', 'GPA', '必修GPA'],
                    bold: true,
                    flexes: const [2, 2, 2, 2, 2, 2],
                  ),
                  const Divider(height: 1),
                  for (final y in summary.years)
                    _row(
                      [
                        gradeOf(y.year),
                        '${y.count}',
                        y.credits.toStringAsFixed(1),
                        y.reqCredits.toStringAsFixed(1),
                        y.gpa?.toStringAsFixed(1) ?? '—',
                        y.reqGpa?.toStringAsFixed(1) ?? '—',
                      ],
                      flexes: const [2, 2, 2, 2, 2, 2],
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text(
            '课程明细',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        for (final sem in sems)
          ExpansionTile(
            title: Text(
              _shortSem(sem),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text('${bySem[sem]!.length} 门课程'),
            children: bySem[sem]!.map(_tile).toList(),
          ),
      ],
    );
  }

  /// "2025-2026 第1学期" → "2025-2026 1"
  static String _shortSem(String s) =>
      s.replaceAll('第', '').replaceAll('学期', '');

  static const _gradeCn = ['一', '二', '三', '四', '五', '六', '七', '八', '九', '十'];

  /// "2025-2026" → 2025；解析不了返回 null
  static int? _startYear(String y) {
    final m = RegExp(r'(\d{4})').firstMatch(y);
    return m == null ? null : int.parse(m.group(1)!);
  }

  Widget _row(
    List<String> cells, {
    bool bold = false,
    List<int> flexes = const [],
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    child: Row(
      children: [
        for (var i = 0; i < cells.length; i++)
          Expanded(
            flex: (i < flexes.length) ? flexes[i] : 1,
            child: Text(
              cells[i],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: bold ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
      ],
    ),
  );

  Widget _stat(String label, String? value) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        value ?? '—',
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      Text(label, style: const TextStyle(fontSize: 12, color: Colors.black54)),
    ],
  );

  Widget _tile(GradeEntry e) => ListTile(
    dense: true,
    title: Text(e.name),
    subtitle: Text(
      '学分 ${e.credit} · 绩点 ${e.gp?.toStringAsFixed(1) ?? '—'}'
      '${e.category.isEmpty ? '' : ' · ${e.category}'}',
      style: const TextStyle(fontSize: 12),
    ),
    trailing: Text(
      e.score?.toStringAsFixed(0) ?? '—',
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
    ),
  );
}

class _CenterError extends StatelessWidget {
  final String msg;
  final Future<void> Function() retry;
  const _CenterError(this.msg, this.retry);

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(msg, textAlign: TextAlign.center),
        ),
        FilledButton.tonal(onPressed: retry, child: const Text('重试')),
      ],
    ),
  );
}
