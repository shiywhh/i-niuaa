// Engine | Flutter 3.x / Dart 3 | lib/ui/phyexp_page.dart
// 大物实验（物理实验预约系统，phyexp.nuaa.edu.cn 将军路口径）：
//   - 未登录：学号 + 密码登录（MD5 由本端算，密码可记住，secure storage）
//   - 已登录：实验课 -> 实验项目列表（已选标记）-> 场次列表（余量 + 选课）
//   - 选课走实测口径 POST report-api/electives（lesson_id + course_id），
//     弹确认框后提交，成功刷新列表
// Deps: dio, crypto, flutter_secure_storage

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/phyexp_client.dart';

class PhyExpScreen extends StatefulWidget {
  const PhyExpScreen({super.key});

  @override
  State<PhyExpScreen> createState() => _PhyExpScreenState();
}

class _PhyExpScreenState extends State<PhyExpScreen> {
  final _client = PhyExpClient.instance;
  var _restored = false;
  var _loggedIn = false;

  @override
  void initState() {
    super.initState();
    _client.restore().then((ok) {
      if (!mounted) return;
      setState(() {
        _restored = true;
        _loggedIn = ok;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_restored) {
      return const Center(child: CircularProgressIndicator());
    }
    return _loggedIn
        ? _PhyExpHome(onLogout: () => setState(() => _loggedIn = false))
        : _PhyExpLoginForm(onLoggedIn: () => setState(() => _loggedIn = true));
  }
}

// ============================================================
// 登录
// ============================================================

class _PhyExpLoginForm extends StatefulWidget {
  const _PhyExpLoginForm({required this.onLoggedIn});

  final VoidCallback onLoggedIn;

  @override
  State<_PhyExpLoginForm> createState() => _PhyExpLoginFormState();
}

class _PhyExpLoginFormState extends State<_PhyExpLoginForm> {
  final _codeCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  var _remember = true;
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _codeCtrl.dispose();
    _pwdCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_busy) return;
    final code = _codeCtrl.text.trim();
    final pwd = _pwdCtrl.text;
    if (code.isEmpty || pwd.isEmpty) {
      setState(() => _error = '请输入学号和密码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await PhyExpClient.instance.login(code, pwd, remember: _remember);
      if (!mounted) return;
      widget.onLoggedIn();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '登录失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      children: [
        const Icon(Icons.science_outlined, size: 56, color: Colors.black45),
        const SizedBox(height: 12),
        const Center(
          child: Text(
            '物理实验预约系统',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
        const Center(
          child: Text(
            '将军路校区 · phyexp.nuaa.edu.cn',
            style: TextStyle(fontSize: 12, color: Colors.black45),
          ),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _codeCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '学号',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pwdCtrl,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: '密码',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _login(),
        ),
        SwitchListTile(
          title: const Text('记住密码', style: TextStyle(fontSize: 13.5)),
          value: _remember,
          onChanged: (v) => setState(() => _remember = v),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _error!,
              style: const TextStyle(color: Color(0xFFB3261E), fontSize: 12.5),
            ),
          ),
        FilledButton(
          onPressed: _busy ? null : _login,
          child: Text(_busy ? '登录中…' : '登录'),
        ),
        const SizedBox(height: 12),
        const Center(
          child: Text(
            '账号密码与统一身份认证不互通，仅存本机加密存储',
            style: TextStyle(fontSize: 11, color: Colors.black38),
          ),
        ),
      ],
    );
  }
}

// ============================================================
// 已登录：课程 -> 实验列表 -> 场次
// ============================================================

class _PhyExpHome extends StatefulWidget {
  const _PhyExpHome({required this.onLogout});

  final VoidCallback onLogout;

  @override
  State<_PhyExpHome> createState() => _PhyExpHomeState();
}

class _PhyExpHomeState extends State<_PhyExpHome> {
  final _client = PhyExpClient.instance;
  var _loading = true;
  String? _error;
  PhyExpCourse? _course;
  PhyExpSemester? _semester;
  List<PhyExpExperiment> _experiments = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final user = _client.user!;
      final sem = await _client.openSemester();
      final courses = await _client.myCourses(sem.id, user.userId);
      if (courses.isEmpty) {
        throw Exception('本学期没有物理实验课');
      }
      final course = courses.first;
      final elected = await _client.electedProjectIds(
        sem.id,
        user.userId,
        course.courseId,
      );
      final exps = await _client.experiments(course.courseId, elected);
      if (!mounted) return;
      setState(() {
        _semester = sem;
        _course = course;
        _experiments = exps;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _logout() async {
    await _client.logout();
    if (!mounted) return;
    widget.onLogout();
  }

  @override
  Widget build(BuildContext context) {
    final user = _client.user!;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${user.name} · ${user.code}',
                  style: const TextStyle(fontSize: 13, color: Colors.black54),
                ),
              ),
              TextButton(onPressed: _load, child: const Text('刷新')),
              TextButton(onPressed: _logout, child: const Text('退出')),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? ListView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!, textAlign: TextAlign.center),
                    ),
                    Center(
                      child: FilledButton.tonal(
                        onPressed: _load,
                        child: const Text('重试'),
                      ),
                    ),
                  ],
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 0, 0, 6),
                        child: Text(
                          '${_course!.courseName}（${_semester!.name}）',
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: Colors.black54,
                          ),
                        ),
                      ),
                      for (final e in _experiments)
                        Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          elevation: 0,
                          clipBehavior: Clip.antiAlias,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                            side: BorderSide(
                              color: e.elected
                                  ? const Color(0x552E7D32)
                                  : Colors.black12,
                            ),
                          ),
                          child: ListTile(
                            title: Text(
                              e.name,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            subtitle: Text(
                              e.elected ? '已选实验' : (e.optional ? '选修' : '必修'),
                              style: TextStyle(
                                fontSize: 12,
                                color: e.elected
                                    ? const Color(0xFF2E7D32)
                                    : Colors.black45,
                              ),
                            ),
                            trailing: const Icon(
                              Icons.chevron_right,
                              color: Colors.black26,
                            ),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => PhyExpLessonsPage(
                                  experiment: e,
                                  course: _course!,
                                  semester: _semester!,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

// ============================================================
// 场次列表 + 选课
// ============================================================

class PhyExpLessonsPage extends StatefulWidget {
  const PhyExpLessonsPage({
    super.key,
    required this.experiment,
    required this.course,
    required this.semester,
  });

  final PhyExpExperiment experiment;
  final PhyExpCourse course;
  final PhyExpSemester semester;

  @override
  State<PhyExpLessonsPage> createState() => _PhyExpLessonsPageState();
}

class _PhyExpLessonsPageState extends State<PhyExpLessonsPage> {
  final _client = PhyExpClient.instance;
  List<PhyExpLesson> _lessons = [];
  var _loading = true;
  String? _error;
  var _bookingScheduleId = -1;
  var _cancellingId = -1;
  Timer? _poll; // 余量自动轮询：30s 静默刷新

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _silentLoad());
  }

  /// 静默刷新：不闪加载态，只更新数据
  Future<void> _silentLoad() async {
    if (_bookingScheduleId != -1 || _cancellingId != -1) return;
    try {
      final lessons = await _client.lessons(
        projectId: widget.experiment.projectId,
        courseId: widget.course.courseId,
        userId: _client.user!.userId,
        classId: widget.course.classId,
        semester: widget.semester,
      );
      if (!mounted) return;
      setState(() => _lessons = lessons);
    } catch (_) {}
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final lessons = await _client.lessons(
        projectId: widget.experiment.projectId,
        courseId: widget.course.courseId,
        userId: _client.user!.userId,
        classId: widget.course.classId,
        semester: widget.semester,
      );
      if (!mounted) return;
      setState(() {
        _lessons = lessons;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _book(PhyExpLesson lesson) async {
    final date = lesson.date;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认选课'),
        content: Text(
          '${widget.experiment.name}\n'
          '上课日期：$date ${lesson.startTime}-${lesson.endTime}\n'
          '${lesson.location} ${lesson.teacher}\n\n确认继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _bookingScheduleId = lesson.scheduleId);
    try {
      await _client.book(lesson.scheduleId, widget.course.courseId);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('选课成功')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('选课失败：$e')));
    } finally {
      if (mounted) setState(() => _bookingScheduleId = -1);
    }
  }

  Future<void> _cancel(PhyExpLesson lesson) async {
    final id = lesson.user2projectId;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认退课'),
        content: Text(
          '${widget.experiment.name}\n'
          '${lesson.date} ${lesson.startTime}-${lesson.endTime}\n\n确定退掉这场？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _cancellingId = id);
    try {
      await _client.cancel(id);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已退课')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('退课失败：$e')));
    } finally {
      if (mounted) setState(() => _cancellingId = -1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final exp = widget.experiment;
    return Scaffold(
      appBar: AppBar(title: Text('实验:${exp.name}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Center(
                  child: FilledButton.tonal(
                    onPressed: _load,
                    child: const Text('重试'),
                  ),
                ),
              ],
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                children: [
                  for (final lesson in _lessons)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      elevation: 0,
                      clipBehavior: Clip.antiAlias,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(
                          color: lesson.bookedByMe
                              ? const Color(0x552E7D32)
                              : Colors.black12,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${lesson.date} ${lesson.startTime}-${lesson.endTime}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    [
                                      if (lesson.location.isNotEmpty)
                                        lesson.location,
                                      if (lesson.teacher.isNotEmpty)
                                        lesson.teacher,
                                      '${lesson.periodName} · '
                                          '已选 ${lesson.currentStudent}/${lesson.maxStudent}',
                                    ].join(' · '),
                                    style: const TextStyle(
                                      fontSize: 11.5,
                                      color: Colors.black45,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            lesson.bookedByMe
                                ? OutlinedButton(
                                    onPressed: _cancellingId != -1
                                        ? null
                                        : () => _cancel(lesson),
                                    child: Text(
                                      _cancellingId == lesson.user2projectId
                                          ? '退课中…'
                                          : '取消',
                                      style: const TextStyle(fontSize: 12.5),
                                    ),
                                  )
                                : FilledButton(
                                    onPressed:
                                        lesson.remaining <= 0 ||
                                            _bookingScheduleId != -1 ||
                                            _cancellingId != -1
                                        ? null
                                        : () => _book(lesson),
                                    child: Text(
                                      _bookingScheduleId == lesson.scheduleId
                                          ? '提交中…'
                                          : (lesson.remaining <= 0
                                                ? '已满'
                                                : '选课'),
                                    ),
                                  ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
