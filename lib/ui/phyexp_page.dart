// Engine | Flutter 3.x / Dart 3 | lib/ui/phyexp_page.dart
// 大物实验（物理实验预约系统，phyexp.nuaa.edu.cn 将军路口径）：
//   - 未登录：学号 + 密码登录（MD5 由本端算，密码可记住，secure storage）
//   - 已登录：实验课 -> 实验项目列表（已选标记）-> 场次列表（余量 + 选课）
//   - 选课走实测口径 POST report-api/electives（lesson_id + course_id），
//     弹确认框后提交，成功刷新列表
// Deps: dio, crypto, flutter_secure_storage

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/current_semester.dart';
import '../core/models.dart';
import '../core/period_times.dart';
import '../core/phyexp_client.dart';

/// EAMS 课表快照（本地缓存）：用于判断物理实验场次与课表冲突
class _EamsTimetable {
  static List<CourseSpan>? _spans;
  static DateTime? _anchor;
  static var _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final semKey = p.getString('tt_last_sem') ?? await CurrentSemester.id();
      if (semKey == null) return;
      final cache = p.getString('tt_cache_v3_$semKey');
      final anchorS = p.getString('tt_anchor_$semKey');
      if (cache == null || anchorS == null) return;
      final j = (jsonDecode(cache) as Map).cast<String, dynamic>();
      final spans = (j['spans'] as List)
          .map((e) => CourseSpan.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
      final anchor = DateTime.tryParse(anchorS);
      if (spans.isEmpty || anchor == null) return;
      _spans = spans;
      _anchor = anchor;
    } catch (_) {}
  }

  /// 场次起止与 EAMS 课表任一上课时段重叠即为冲突；
  /// 无课表缓存/无锚点时不算冲突（没法判就不拦）
  static bool conflicts(DateTime lessonStart, DateTime lessonEnd) {
    final spans = _spans;
    final anchor = _anchor;
    if (spans == null || anchor == null) return false;
    final days = lessonStart
        .difference(DateTime(anchor.year, anchor.month, anchor.day))
        .inDays;
    if (days < 0) return false;
    final week = days ~/ 7 + 1;
    final times = PeriodTimesStore.instance.times;
    for (final span in spans) {
      if (span.weekday != lessonStart.weekday) continue;
      final ws = span.weekSet;
      if (ws.isNotEmpty && !ws.contains(week)) continue;
      if (span.startUnit >= times.length || span.endUnit >= times.length) {
        continue;
      }
      final sm = times[span.startUnit].startMinutes;
      final em = times[span.endUnit].endMinutes;
      final ss = DateTime(
        lessonStart.year,
        lessonStart.month,
        lessonStart.day,
        sm ~/ 60,
        sm % 60,
      );
      final se = DateTime(
        lessonStart.year,
        lessonStart.month,
        lessonStart.day,
        em ~/ 60,
        em % 60,
      );
      if (ss.isBefore(lessonEnd) && lessonStart.isBefore(se)) return true;
    }
    return false;
  }
}

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
  String _campus = PhyExpClient.instance.campus;

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
      await PhyExpClient.instance.setCampus(_campus);
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
        const SizedBox(height: 24),
        SegmentedButton<String>(
          segments: [
            for (final c in phyexpCampuses.keys)
              ButtonSegment(
                value: c,
                label: Text(c, style: const TextStyle(fontSize: 12)),
              ),
          ],
          selected: {_campus},
          onSelectionChanged: (sel) => setState(() => _campus = sel.first),
        ),
        const SizedBox(height: 16),
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
        CheckboxListTile(
          title: const Text('记住密码', style: TextStyle(fontSize: 13.5)),
          value: _remember,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          contentPadding: EdgeInsets.zero,
          onChanged: (v) => setState(() => _remember = v ?? true),
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
  List<PhyExpMyExperiment> _mine = [];
  final Map<int, List<int>> _counts = {}; // projectId -> [未选满, 未冲突]

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
      final mine = await _client.myExperiments(
        sem.id,
        user.userId,
        course.courseId,
      );
      if (!mounted) return;
      setState(() {
        _semester = sem;
        _course = course;
        _experiments = exps;
        _mine = mine;
        _counts.clear();
      });
      if (!mounted) return;
      // 逐实验拉场次算"未选满/未冲突"数（已选的不算），4 个并发一批
      await _EamsTimetable.load();
      await PeriodTimesStore.instance.ensureLoaded();
      final pool = exps.where((e) => !e.elected).toList();
      for (var i = 0; i < pool.length; i += 4) {
        final batch = pool.skip(i).take(4).toList();
        final results = await Future.wait(
          batch
              .map(
                (e) => _client.lessons(
                  projectId: e.projectId,
                  courseId: course.courseId,
                  userId: user.userId,
                  classId: course.classId,
                  semester: sem,
                ),
              )
              .toList(),
        );
        if (!mounted) return;
        for (var k = 0; k < batch.length; k++) {
          final ls = results[k];
          final m = ls.where((l) => l.remaining > 0).length;
          final n = ls
              .where(
                (l) =>
                    l.remaining > 0 &&
                    !_EamsTimetable.conflicts(l.start, l.end),
              )
              .length;
          if (!mounted) return;
          setState(() => _counts[batch[k].projectId] = [m, n]);
        }
      }
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _cancelMine(PhyExpMyExperiment m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认退课'),
        content: Text(
          '${m.name}\n'
          '${m.date} ${m.startTime}-${m.endTime}\n\n确定退掉这场？',
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
    try {
      await _client.cancel(m.user2projectId);
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
    }
  }

  /// 下载实验报告/讲义：应用内下载（进度框）-> 完成后用系统程序打开
  Future<void> _downloadReport(PhyExpMyExperiment m) async {
    // 保存位置：Android 用应用专属外部目录（无需权限），Windows 用下载目录
    String dirPath;
    if (Platform.isAndroid) {
      final dirs = await getExternalStorageDirectories();
      dirPath = dirs?.first.path ?? (await getTemporaryDirectory()).path;
    } else if (Platform.isWindows) {
      dirPath =
          (await getDownloadsDirectory())?.path ??
          (await getTemporaryDirectory()).path;
    } else {
      dirPath = (await getTemporaryDirectory()).path;
    }
    final token = CancelToken();
    final progress = ValueNotifier<List<int>>(const [0, 0]);
    var dialogOpen = true;
    BuildContext? dialogCtx;

    void closeProgress() {
      if (!dialogOpen) return;
      dialogOpen = false;
      final ctx = dialogCtx;
      if (ctx != null && ctx.mounted) Navigator.pop(ctx);
    }

    if (!mounted) return; // 目录解析期间页面可能已退出
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogCtx = ctx;
        return AlertDialog(
          title: const Text('下载文件'),
          content: ValueListenableBuilder<List<int>>(
            valueListenable: progress,
            builder: (_, v, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: v[1] > 0 ? v[0] / v[1] : null),
                const SizedBox(height: 10),
                Text(
                  v[1] > 0
                      ? '${(v[0] / 1024).toStringAsFixed(0)} / ${(v[1] / 1024).toStringAsFixed(0)} KB'
                      : '连接中…',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                token.cancel('用户取消');
                closeProgress();
              },
              child: const Text('取消'),
            ),
          ],
        );
      },
    );

    String? failure;
    String? savePath;
    try {
      final res =
          await Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 30),
              headers: {'User-Agent': 'i-niuaa'},
            ),
          ).get<List<int>>(
            _client.reportPaperUrl(m.user2projectId),
            options: Options(responseType: ResponseType.bytes),
            onReceiveProgress: (r, t) => progress.value = [r, t],
            cancelToken: token,
          );
      // 文件名优先取响应头，取不到按实验名兜底（默认 PDF）
      var name = 'phyexp_${m.user2projectId}';
      final cd = res.headers.value('content-disposition');
      final m2 = cd == null
          ? null
          : RegExp(r"""filename\*?=(?:UTF-8'')?"?([^;"]+)""").firstMatch(cd);
      if (m2 != null) {
        name = m2.group(1)!;
      } else if (m.name.isNotEmpty) {
        name = m.name;
      }
      if (!name.contains('.')) name = '$name.pdf';
      name = name.replaceAll(RegExp(r'[\/:*?"<>|]'), '_');
      savePath = '$dirPath/$name';
      final f = File(savePath);
      if (f.existsSync()) f.deleteSync();
      f.writeAsBytesSync(res.data!);
    } on DioException catch (e) {
      if (e.type != DioExceptionType.cancel) failure = '下载失败，请重试';
    } catch (_) {
      failure = '下载失败，请重试';
    }
    closeProgress();
    if (token.isCancelled) return;
    if (failure != null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(failure)));
      }
      return;
    }

    // 打开文件：Android 系统查看器，Windows 默认程序
    try {
      if (Platform.isAndroid) {
        final res = await OpenFilex.open(savePath!);
        if (mounted && res.type != ResultType.done) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('已下载：$savePath（无法直接打开）')));
        }
      } else if (Platform.isWindows) {
        await Process.start('explorer.exe', [
          savePath!,
        ], mode: ProcessStartMode.detached);
      } else if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已下载：$savePath')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已下载：\$savePath（打开失败：\$e）')));
      }
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
                      if (_mine.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 0, 0, 6),
                          child: Text(
                            '我的实验（${_mine.length}）',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        for (final m in _mine)
                          Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            color: const Color(0x142E7D32),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                              side: const BorderSide(color: Color(0x552E7D32)),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          m.name,
                                          style: const TextStyle(
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.bold,
                                            color: Color(0xFF2E7D32),
                                          ),
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: m.liveStatus == '进行中'
                                              ? const Color(0x1AB8860B)
                                              : m.liveStatus == '已结束'
                                              ? const Color(0x14000000)
                                              : const Color(0x142E7D32),
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                        ),
                                        child: Text(
                                          m.liveStatus,
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.bold,
                                            color: m.liveStatus == '进行中'
                                                ? const Color(0xFFB8860B)
                                                : m.liveStatus == '已结束'
                                                ? Colors.black45
                                                : const Color(0xFF2E7D32),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '${m.date} ${m.startTime}-${m.endTime}',
                                    style: const TextStyle(fontSize: 12.5),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    [
                                      if (m.location.isNotEmpty) m.location,
                                      if (m.teacher.isNotEmpty) m.teacher,
                                      if (m.periodName.isNotEmpty) m.periodName,
                                    ].where((x) => x.isNotEmpty).join(' · '),
                                    style: const TextStyle(
                                      fontSize: 11.5,
                                      color: Colors.black54,
                                    ),
                                  ),
                                  // 进行中/已结束：签到、报告、答题等在微信端完成
                                  if (m.liveStatus != '未开始') ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      '请前往微信进一步操作',
                                      style: const TextStyle(
                                        fontSize: 11.5,
                                        color: Colors.black38,
                                      ),
                                    ),
                                  ],
                                  if (m.liveStatus == '未开始') ...[
                                    const SizedBox(height: 8),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        OutlinedButton(
                                          onPressed: () => _cancelMine(m),
                                          style: OutlinedButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 14,
                                            ),
                                            minimumSize: const Size(0, 32),
                                          ),
                                          child: const Text(
                                            '取消',
                                            style: TextStyle(fontSize: 12),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        FilledButton.tonal(
                                          onPressed: () => _downloadReport(m),
                                          style: FilledButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 14,
                                            ),
                                            minimumSize: const Size(0, 32),
                                          ),
                                          child: const Text(
                                            '下载',
                                            style: TextStyle(fontSize: 12),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        const SizedBox(height: 12),
                      ],
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 0, 0, 6),
                        child: Text(
                          '全部实验',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
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
  var _onlySelectable = true; // 选课时间过滤：隐藏已开始/已满场次
  Timer? _poll; // 余量自动轮询：30s 静默刷新

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _silentLoad());
  }

  /// 选课时间过滤后的可见场次：开关开启时隐藏已开始/已满的
  List<PhyExpLesson> get _visibleLessons {
    if (!_onlySelectable) return _lessons;
    final now = DateTime.now();
    return _lessons.where((l) {
      if (l.bookedByMe) return true; // 自己已选的保留（可退）
      final start = DateTime.tryParse('${l.date}T${l.startTime}');
      if (start == null) return true;
      return start.isAfter(now) && l.remaining > 0;
    }).toList();
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
                  CheckboxListTile(
                    title: const Text(
                      '仅显示可选',
                      style: TextStyle(fontSize: 13.5),
                    ),
                    subtitle: Text(
                      '隐藏已开始或已满的场次（${_visibleLessons.length}/${_lessons.length}）',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.black45,
                      ),
                    ),
                    value: _onlySelectable,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    onChanged: (v) =>
                        setState(() => _onlySelectable = v ?? true),
                  ),
                  for (final lesson in _visibleLessons)
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
                                    lesson.date,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '${lesson.startTime} - ${lesson.endTime}',
                                    style: const TextStyle(fontSize: 12.5),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    [
                                      if (lesson.location.isNotEmpty)
                                        lesson.location,
                                      if (lesson.teacher.isNotEmpty)
                                        lesson.teacher,
                                      lesson.periodName,
                                    ].where((x) => x.isNotEmpty).join(' · '),
                                    style: const TextStyle(
                                      fontSize: 11.5,
                                      color: Colors.black45,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '已选 ${lesson.currentStudent}/'
                                    '${lesson.maxStudent}',
                                    style: const TextStyle(
                                      fontSize: 11.5,
                                      color: Colors.black54,
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
