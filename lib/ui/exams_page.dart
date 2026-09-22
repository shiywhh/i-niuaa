// Engine | Flutter 3.x / Dart 3 | lib/ui/exams_page.dart
// 考试页：学年学期选择 + examTable 全批次考试安排

import 'package:flutter/material.dart';

import '../core/current_semester.dart';
import '../core/models.dart';
import '../core/session.dart';

class ExamsPage extends StatefulWidget {
  const ExamsPage({super.key});

  @override
  State<ExamsPage> createState() => _ExamsPageState();
}

class _ExamsPageState extends State<ExamsPage> {
  List<Semester> _semesters = const [];
  String? _semId; // 默认最新学期
  List<List<String>>? _rows; // [序号,名称,类别,日期,安排,地点,校区,座位,情况,说明]
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

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
    } catch (e) {
      if (mounted) setState(() => _error = '学期列表获取失败：$e');
    }
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      if (_semesters.isEmpty) {
        _semesters = await Session.I.guard(Session.I.eams.semesters);
      }
      final rows = await Session.I.guard(
        () => Session.I.eams.examTable(semesterId: _semId),
      );
      if (mounted) setState(() => _rows = rows);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    if (_error != null) return _retry(_error!, _load);
    if (rows == null) return const Center(child: CircularProgressIndicator());

    return Column(
      children: [
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
        Expanded(child: _buildList(rows)),
      ],
    );
  }

  Widget _buildList(List<List<String>> rows) {
    if (rows.isEmpty) {
      return const Center(
        child: Text('该学期暂无考试安排', style: TextStyle(color: Colors.black45)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(10),
      itemCount: rows.length,
      itemBuilder: (_, i) {
        final r = rows[i];
        String at(int idx) => (idx < r.length) ? r[idx] : '';
        final lines = <String>[
          if (at(3).isNotEmpty) '考试日期：${at(3)}',
          if (at(4).isNotEmpty) '考试安排：${at(4)}',
          if (at(5).isNotEmpty || at(6).isNotEmpty)
            '考试地点：${at(5)}${at(6).isEmpty ? '' : '（${at(6)}）'}',
          if (at(7).isNotEmpty) '座位号：${at(7)}',
          if (at(8).isNotEmpty) '考试情况：${at(8)}',
          if (at(9).isNotEmpty) '备注：${at(9)}',
        ];
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
                        at(1),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    if (at(2).isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: .1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          at(2),
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  at(0),
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
                if (lines.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  for (final l in lines)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        l,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                ],
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
