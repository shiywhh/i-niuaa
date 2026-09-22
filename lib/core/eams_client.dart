// Engine | Flutter 3.x / Dart 3 | lib/core/eams_client.dart
// 三个页面全部按 2026-09 实测 HTML 结构钉死：
//   课表   /eams/courseTableForStd.action                  (#grid 表格)
//   成绩   /eams/teach/grade/course/person-grade.action    (固定列头，含绩点)
//   考试   /eams/examSearchForStd.action                   (批次下拉 + POST examBatch.id)
//   选课   /eams/stdElectCourse!data.action / !batchOperator.action（Xuanke_v2 链路）
// 会话失效特征：HTTP 3xx（被弹去 CAS）或页面含 casLoginForm -> SessionExpired

import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;

import 'models.dart';

class SessionExpired implements Exception {
  final String message = '登录已过期，请重新登录';
  SessionExpired();
  @override
  String toString() => message;
}

class EamsClient {
  final Dio dio;
  EamsClient(this.dio);

  static const host = 'https://aao-eas.nuaa.edu.cn';

  /// 统一取 HTML。会话失效被弹去 CAS 时，若 CAS 还有 SSO 会自动带 ticket
  /// 跳回原页面（自愈）；跟完仍落在 authserver 域才算会话死。
  Future<String> _fetch(String url, {Map<String, String>? form}) async {
    var current = url;
    Map<String, String>? body = form;
    for (var hop = 0; hop < 8; hop++) {
      final res = body == null
          ? await dio.get(current)
          : await dio.post(current,
              data: body,
              options: Options(contentType: Headers.formUrlEncodedContentType));
      final status = res.statusCode ?? 0;
      final loc = res.headers.value('location');
      if (status >= 300 && status < 400 && loc != null) {
        current = _abs(current, loc);
        body = null; // 3xx 之后一律 GET
        continue;
      }
      final html = res.data as String;
      // 被弹回 CAS 登录页 = 会话失效
      if (Uri.parse(current).host.contains('authserver')) {
        throw SessionExpired();
      }
      if (html.contains('casLoginForm')) throw SessionExpired();
      return html;
    }
    throw SessionExpired();
  }

  String _abs(String base, String loc) {
    if (loc.startsWith('http://') || loc.startsWith('https://')) return loc;
    final b = Uri.parse(base);
    final root = '${b.scheme}://${b.host}'
        '${b.hasPort ? ':${b.port}' : ''}';
    return loc.startsWith('/') ? '$root$loc' : '$root/$loc';
  }

  /// 学期列表（新→旧），来自课表页日历控件的数据源
  Future<List<Semester>> semesters() async {
    final formHtml = await _fetch('$host/eams/courseTableForStd.action');
    return _semestersFromForm(formHtml);
  }

  Future<List<Semester>> _semestersFromForm(String formHtml) async {
    final tagId = RegExp(r'id="(semesterBar\d+Semester)"')
        .firstMatch(formHtml)
        ?.group(1);
    if (tagId == null) return const [];
    try {
      final res = await dio.post('$host/eams/dataQuery.action',
          data: {
            'tagId': tagId,
            'dataType': 'semesterCalendar',
            'value': '',
            'empty': 'false'
          },
          options: Options(contentType: Headers.formUrlEncodedContentType));
      final body = res.data as String;
      if (body.contains('casLoginForm')) return const [];
      final entries = RegExp(r'\{id:(\d+),schoolYear:"([^"]+)",name:"([^"]+)"\}')
          .allMatches(body)
          .map((m) => (m.group(1)!, m.group(2)!, m.group(3)!))
          .toList();
      entries.sort((a, b) {
        final y = b.$2.compareTo(a.$2);
        return y != 0 ? y : b.$3.compareTo(a.$3);
      });
      return entries.map((e) => Semester(e.$1, '${e.$2} 第${e.$3}学期')).toList();
    } catch (_) {
      return const [];
    }
  }

  /// 课表：新版 EAMS UI 需要两步 ——
  ///   1) GET courseTableForStd.action 表单页，抠出学生内部 id（searchTable 里的
  ///      addInput(form,"ids","N")）和当前学期（semesterCalendar 的 value:"N"）
  ///   2) 完全复刻 bg.form.submit 的 POST 到 !courseTable.action
  /// 缺 ids 时服务端只回 error.courseTable.unknown。
  /// 网格数据在页面内嵌 JS 里（var table0 + new TaskActivity(...)），
  /// HTML 的 td 是空壳，由前端渲染 —— 所以直接解析 JS 文本。
  Future<CourseTableData> courseTable({String? semesterId}) async {
    final formHtml = await _fetch('$host/eams/courseTableForStd.action');
    final ids =
        RegExp(r'addInput\(form,"ids","(\d+)"').firstMatch(formHtml)?.group(1);
    final curSemId = RegExp(r'semesterCalendar\(\{[^}]*value:"(\d+)"')
        .firstMatch(formHtml)
        ?.group(1);
    if (ids == null) throw SessionExpired();

    // 学期列表（日历控件数据源：dataQuery.action）
    final semesters = await _semestersFromForm(formHtml);

    final chosen = semesterId ??
        curSemId ??
        (semesters.isNotEmpty ? semesters.first.id : '');
    final html = await _fetch('$host/eams/courseTableForStd!courseTable.action',
        form: {
          'ignoreHead': '1',
          'setting.kind': 'std',
          'startWeek': '',
          'project.id': '',
          'semester.id': chosen,
          'ids': ids,
        });

    // 学期名与当前教学周从首页横幅取（服务端权威值）
    var semesterName = '当前学期';
    int? currentWeek;
    for (final s in semesters) {
      if (s.id == chosen) {
        semesterName = s.name;
        break;
      }
    }
    if (chosen == curSemId || chosen.isEmpty) {
      try {
        final home = await _fetch('$host/eams/homeExt.action');
        // 数字与"教学周"之间可能隔着标签，先剥掉再匹配
        final homeText = home.replaceAll(RegExp(r'<[^>]+>'), ' ');
        semesterName =
            RegExp(r'20\d{2}-20\d{2}第\d学期').firstMatch(homeText)?.group(0) ??
                semesterName;
        currentWeek =
            int.tryParse(RegExp(r'(\d+)\s*教学周').firstMatch(homeText)?.group(1) ?? '');
      } catch (_) {}
    }

    final start = html.indexOf('var table0');
    if (start < 0) throw SessionExpired();
    final js = html.substring(start);

    final spans = <CourseSpan>[];
    // 每个 activity 块：var teachers = [...]; ... new TaskActivity(...); index = d*unitCount+u; ×n
    final segments = js.split('var teachers = [');
    for (var s = 1; s < segments.length; s++) {
      final seg = segments[s];
      final headEnd = seg.indexOf(']');
      if (headEnd < 0) continue;
      final teacher = RegExp(r'name:"([^"]+)"')
          .allMatches(seg.substring(0, headEnd))
          .map((m) => m.group(1)!)
          .join(',');

      final actStart = seg.indexOf('new TaskActivity(');
      if (actStart < 0) continue;
      final argsEnd = seg.indexOf(');', actStart);
      if (argsEnd < 0) continue;
      final args = _splitArgs(seg.substring(actStart + 17, argsEnd));
      if (args.length < 14) continue;
      final name = args[3];
      final room = args[6];
      final bitmap = args[7];
      if (name.isEmpty || bitmap.isEmpty) continue;

      final weeks = <int>{};
      for (var i = 0; i < bitmap.length; i++) {
        if (bitmap[i] == '1') weeks.add(i); // 位图下标即周次（下标 0 为占位）
      }
      final weeksStr = _formatWeeks(weeks);

      // 本块内所有格子坐标：index = day*unitCount+unit;（段界即块界，扫到段尾）
      // 同一 activity 的坐标按天归并：min..max 单元收成一个连续时段，一张卡
      final slotRe = RegExp(r'index\s*=\s*(\d+)\s*\*\s*unitCount\s*\+\s*(\d+)\s*;');
      final unitsByDay = <int, List<int>>{};
      for (final m in slotRe.allMatches(seg.substring(argsEnd))) {
        unitsByDay
            .putIfAbsent(int.parse(m.group(1)!), () => [])
            .add(int.parse(m.group(2)!));
      }
      for (final e in unitsByDay.entries) {
        final units = e.value.toSet().toList()..sort();
        spans.add(CourseSpan(name, teacher, weeksStr, room, e.key + 1,
            startUnit: units.first, endUnit: units.last));
      }
    }
    // 课程列表表（课表网格之外的"课程列表"表格）
    final doc = html_parser.parse(html);
    final courseList = <CourseListItem>[];
    List<int>? cIdx;
    for (final tr in doc.querySelectorAll('tr')) {
      final cells =
          tr.querySelectorAll('th,td').map((c) => c.text.trim()).toList();
      if (cells.isEmpty) continue;
      if (cIdx == null) {
        final iCode = cells.indexWhere((c) => c.contains('课程代码'));
        final iName = cells.indexWhere((c) => c.contains('课程名称'));
        if (iCode < 0 || iName < 0) continue;
        int f(bool Function(String) t) => cells.indexWhere(t);
        cIdx = [
          f((c) => c.contains('课程序号')),
          iCode,
          iName,
          f((c) => c.contains('课程类别')),
          f((c) => c == '学分'),
          f((c) => c.contains('教师')),
          f((c) => c.contains('教学班')),
        ];
        continue;
      }
      String at(int i) => (i >= 0 && i < cells.length) ? cells[i] : '';
      if (at(cIdx[1]).isEmpty) continue;
      courseList.add(CourseListItem(
        at(cIdx[0]), at(cIdx[1]), at(cIdx[2]), at(cIdx[3]),
        at(cIdx[4]), at(cIdx[5]), at(cIdx[6]),
      ));
    }
    return CourseTableData(
        semesterName, chosen, semesters, spans, currentWeek, courseList);
  }

  /// 引号感知的参数切分（参数里有 join(',') / join(",") 这类带引号逗号的表达式）
  List<String> _splitArgs(String raw) {
    final out = <String>[];
    final buf = StringBuffer();
    String? quote; // 当前未闭合的引号类型（' 或 "）
    for (var i = 0; i < raw.length; i++) {
      final ch = raw[i];
      if (quote != null) {
        if (ch == quote) {
          quote = null;
        } else {
          buf.write(ch);
        }
        continue;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
        continue;
      }
      if (ch == ',') {
        out.add(buf.toString().trim());
        buf.clear();
        continue;
      }
      buf.write(ch);
    }
    out.add(buf.toString().trim());
    return out;
  }

  String _formatWeeks(Set<int> weeks) {
    if (weeks.isEmpty) return '';
    final sorted = weeks.toList()..sort();
    final parts = <String>[];
    var a = sorted.first, b = a;
    for (final w in sorted.skip(1)) {
      if (w == b + 1) {
        b = w;
        continue;
      }
      parts.add(a == b ? '$a' : '$a-$b');
      a = b = w;
    }
    parts.add(a == b ? '$a' : '$a-$b');
    return parts.join(',');
  }

  /// 全部学期成绩（无参数，一页返回）
  Future<List<GradeEntry>> grades() async {
    final doc =
        html_parser.parse(await _fetch('$host/eams/teach/grade/course/person-grade.action'));

    final out = <GradeEntry>[];
    List<int>? idx;
    for (final tr in doc.querySelectorAll('tr')) {
      final cells =
          tr.querySelectorAll('th,td').map((c) => c.text.trim()).toList();
      if (cells.isEmpty) continue;

      if (idx == null) {
        final iName = cells.indexWhere((c) => c.contains('课程名称'));
        final iFinal = cells.indexWhere((c) => c.contains('最终') || c == '成绩');
        final iGp = cells.indexWhere((c) => c.contains('绩点'));
        if (iName < 0 || iFinal < 0 || iGp < 0) continue;
        int f(bool Function(String) t) => cells.indexWhere(t);
        idx = [
          f((c) => c.contains('学年学期')),
          iName,
          f((c) => c == '学分'),
          iFinal,
          iGp,
          f((c) => c.contains('获得学分')),
          f((c) => c.contains('课程类别')),
        ];
        continue;
      }

      String at(int i) => (i >= 0 && i < cells.length) ? cells[i] : '';
      final name = at(idx[1]);
      if (name.isEmpty) continue;
      out.add(GradeEntry(
        at(idx[0]),
        name,
        at(idx[6]),
        double.tryParse(at(idx[2])) ?? 0,
        double.tryParse(at(idx[5])),
        double.tryParse(at(idx[3])),
        double.tryParse(at(idx[4])),
      ));
    }
    return out;
  }

  Future<List<ExamBatch>> examBatches({String? semesterId}) async {
    final doc = html_parser.parse(await _fetch('$host/eams/examSearchForStd.action',
        form: semesterId == null
            ? null
            : {'semester.id': semesterId, 'project.id': ''}));
    return doc
        .querySelectorAll('select[name="examBatch.id"] option')
        .where((o) => (o.attributes['value'] ?? '').isNotEmpty)
        .map((o) => ExamBatch(o.attributes['value']!, o.text.trim()))
        .toList();
  }

  /// 指定学期 + 批次的考试课程表（POST 与网页表单同款字段）
  Future<List<ExamCourse>> examCourses(String batchId,
      {String? semesterId}) async {
    final doc = html_parser.parse(await _fetch('$host/eams/examSearchForStd.action',
        form: {
          'examBatch.id': batchId,
          'project.id': '',
          'semester.id': semesterId ?? '',
        }));

    final out = <ExamCourse>[];
    List<int>? idx;
    for (final tr in doc.querySelectorAll('tr')) {
      final cells =
          tr.querySelectorAll('th,td').map((c) => c.text.trim()).toList();
      if (cells.isEmpty) continue;

      if (idx == null) {
        final iNo = cells.indexWhere((c) => c.contains('课程序号'));
        final iName = cells.indexWhere((c) => c == '课程名称');
        final iDept = cells.indexWhere((c) => c.contains('院系'));
        final iCredit = cells.indexWhere((c) => c == '学分');
        if (iNo < 0 || iName < 0) continue;
        idx = [iNo, iName, iDept, iCredit];
        continue;
      }

      String at(int i) => (i >= 0 && i < cells.length) ? cells[i] : '';
      if (at(idx[1]).isEmpty) continue;
      out.add(ExamCourse(at(idx[0]), at(idx[1]), at(idx[2]), at(idx[3])));
    }
    return out;
  }

  /// 补选/重修课程目录（stdByElectCourse 单页应用的数据接口）
  Future<List<ElectiveCourse>> electCatalog() async {
    final page = await _fetch('$host/eams/stdByElectCourse.action');
    final pid =
        RegExp(r'!data\.action\?profileId=(\d+)').firstMatch(page)?.group(1);
    if (pid == null) throw SessionExpired();

    final res = await dio.get('$host/eams/stdByElectCourse!data.action?profileId=$pid');
    final body = res.data as String;

    final courses = <ElectiveCourse>[];
    final segs = body.split('{id:');
    for (var i = 1; i < segs.length; i++) {
      final seg = segs[i];
      // 字段值有带引号字符串和不带引号数字两种形态，都要兜
      String? q(String field) =>
          RegExp("$field:'([^']*)'").firstMatch(seg)?.group(1) ??
          RegExp('$field:([0-9.]+)').firstMatch(seg)?.group(1);
      final name = q('name');
      final no = q('no');
      if (name == null || name.isEmpty || no == null) continue;

      final digests = <String>[];
      for (final am
          in RegExp(r'weekDay:(\d+),[^{}]*?startUnit:(\d+),endUnit:(\d+)')
              .allMatches(seg)) {
        const days = ['', '一', '二', '三', '四', '五', '六', '日'];
        final wd = int.parse(am.group(1)!);
        if (wd >= 1 && wd <= 7) {
          digests.add(
              '周${days[wd]} ${am.group(2)}-${am.group(3)}节');
        }
      }

      courses.add(ElectiveCourse(
        seg.substring(0, seg.indexOf(',')),
        no,
        name,
        q('teachers') ?? '',
        q('teachClassName') ?? '',
        q('campusName') ?? '',
        q('courseTypeName') ?? '',
        q('stdCount') ?? '0',
        q('limitCount') ?? '0',
        double.tryParse(q('credits') ?? '') ?? 0,
        digests,
      ));
    }
    return courses;
  }

  // ── 学期选课（补选轮次抢课）────────────────────────────
  // 链路按 Xuanke_v2（NUAA-Snatcher）实测逻辑移植：
  //   档案 ID 候选 ← defaultPage 页面里的 profileId / electionProfile.id
  //   课程数据     ← stdElectCourse!data.action?electionProfile.id=N（备选 profileId=N）
  //   提交         ← stdElectCourse!batchOperator.action?…（optype=true, operator0={id}:true:0, lesson0={id}）

  static final _electPidPatterns = [
    // 与 Xuanke_v2 _ID_PATTERNS 同款：profileId / electionProfile.id，键后可带引号
    RegExp(
        '(?:\\bprofileId\\b|\\belectionProfile\\.id\\b)\\s*[:=]\\s*[\'"]?(\\d+)'),
    RegExp(r'(?:\?|&)(?:profileId|electionProfile\.id)=(\d+)'),
  ];

  List<String> _extractElectPids(String html) {
    final out = <String>[];
    final seen = <String>{};
    for (final pat in _electPidPatterns) {
      for (final m in pat.allMatches(html)) {
        final v = m.group(1)!;
        if (seen.add(v)) out.add(v);
      }
    }
    return out;
  }

  /// 选课档案（electionProfile）ID 候选，从选课入口页抠
  Future<List<String>> electProfileIds() async {
    for (final path in const [
      '/eams/stdElectCourse!defaultPage.action',
      '/eams/stdElectCourse.action',
    ]) {
      try {
        final ids = _extractElectPids(await _fetch('$host$path'));
        if (ids.isNotEmpty) return ids;
      } on SessionExpired {
        rethrow;
      } catch (_) {}
    }
    return const [];
  }

  /// 预热：进一次 defaultPage，让服务端把档案写进会话（与网页打开选课页等价）
  Future<void> warmElect(String pid) async {
    try {
      await _fetch(
          '$host/eams/stdElectCourse!defaultPage.action?electionProfile.id=$pid');
    } catch (_) {}
  }

  /// 选课轮次课程目录。返回 (课程, 实际生效的 pid, 使用的参数名)。
  /// 先按给定 pid 试两种参数名；都不成形时从入口页反抠候选 pid 再试。
  Future<(List<ElectLesson>, String, String)> electLessons(String pid) async {
    final tried = <String>{};
    Future<(List<ElectLesson>, String, String)?> tryPid(String cand) async {
      if (!tried.add(cand)) return null;
      await warmElect(cand);
      for (final param in const ['electionProfile.id', 'profileId']) {
        final String body;
        try {
          body = await _fetch('$host/eams/stdElectCourse!data.action?$param=$cand');
        } on SessionExpired {
          rethrow;
        } catch (_) {
          continue;
        }
        // 课程数据是 JS 对象字面量；落到 HTML 页 = 参数/轮次不对
        if (body.contains('id:') && !body.toLowerCase().contains('<html')) {
          return (_parseElectLessons(body), cand, param);
        }
      }
      return null;
    }

    final direct = await tryPid(pid);
    if (direct != null && direct.$1.isNotEmpty) return direct;
    for (final cand in await electProfileIds()) {
      final r = await tryPid(cand);
      if (r != null && r.$1.isNotEmpty) return r;
    }
    throw Exception('未取到课程数据（检查档案 ID，或选课轮次未开放）');
  }

  List<ElectLesson> _parseElectLessons(String body) {
    final out = <ElectLesson>[];
    final seen = <String>{};

    // 首选：{id: 分段（与 stdByElectCourse 数据同族，字段值有带引号/纯数字两种形态）
    for (final seg in body.split('{id:').skip(1)) {
      final comma = seg.indexOf(',');
      if (comma <= 0) continue;
      final id = seg.substring(0, comma);
      if (!RegExp(r'^\d+$').hasMatch(id) || !seen.add(id)) continue;
      String? q(String f) =>
          RegExp("$f:'([^']*)'").firstMatch(seg)?.group(1) ??
          RegExp('$f:([0-9.]+)').firstMatch(seg)?.group(1);
      final name = q('name') ?? q('courseName');
      if (name == null || name.isEmpty) continue;
      out.add(ElectLesson(
          id, name, q('code') ?? '', q('teachers') ?? q('teacherName') ?? ''));
    }
    if (out.isNotEmpty) return out;

    // 兜底：Xuanke_v2 的配对法 —— 全局 id 序列 × code: 分段的 name 序列按序 zip
    final ids =
        RegExp(r'id:(\d+),').allMatches(body).map((m) => m.group(1)!).toList();
    final names = <String>[];
    for (final item in body.split('code:')) {
      final m = RegExp("name:'([^']*)'").firstMatch(item);
      if (m != null) names.add(m.group(1)!);
    }
    final n = ids.length < names.length ? ids.length : names.length;
    for (var i = 0; i < n; i++) {
      if (seen.add(ids[i])) out.add(ElectLesson(ids[i], names[i], '', ''));
    }
    return out;
  }

  /// 提交一门课：单次 POST，不重试 —— 重试/主备切换/限速退避由调用方控制。
  /// [param] 为本次使用的参数名，调用方按主备顺序轮换。
  Future<ElectSubmitResult> electSubmitOnce(String pid,
      {required String param, required String courseId}) async {
    final url = '$host/eams/stdElectCourse!batchOperator.action?$param=$pid';
    var current = url;
    var resp = await dio.post(
      url,
      data: {
        'optype': 'true',
        'operator0': '$courseId:true:0',
        'lesson0': courseId,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        validateStatus: (_) => true, // 429/5xx 也要拿到状态码做退避判定
        headers: {
          'X-Requested-With': 'XMLHttpRequest',
          'Referer':
              '$host/eams/stdElectCourse!defaultPage.action?electionProfile.id=$pid',
        },
      ),
    );

    // 跟 3xx（全局 followRedirects=false）；被弹去 authserver = 会话失效
    for (var hop = 0; hop < 8; hop++) {
      final status = resp.statusCode ?? 0;
      final loc = resp.headers.value('location');
      if (status >= 300 && status < 400 && loc != null) {
        current = _abs(current, loc);
        resp = await dio.get(current,
            options: Options(validateStatus: (_) => true));
        continue;
      }
      final body = resp.data?.toString() ?? '';
      if (Uri.parse(current).host.contains('authserver') ||
          body.contains('casLoginForm')) {
        throw SessionExpired();
      }
      final msg = RegExp(r'[\u4e00-\u9fa5]+')
          .allMatches(body)
          .map((m) => m.group(0))
          .join();
      final text = msg.isNotEmpty
          ? msg
          : (body.length > 180 ? body.substring(0, 180) : body);
      final ElectVerdict verdict;
      if (text.contains('成功')) {
        verdict = ElectVerdict.ok;
      } else if (body.contains('请不要过快点击') ||
          status == 429 ||
          status == 503) {
        verdict = ElectVerdict.rateLimited;
      } else if (text.contains('失败') ||
          text.contains('错误') ||
          status >= 400) {
        verdict = ElectVerdict.fail;
      } else {
        verdict = ElectVerdict.neutral;
      }
      return ElectSubmitResult(status, text, verdict);
    }
    throw Exception('batchOperator 重定向次数过多');
  }

  /// 通用页面：提示语 + 表格（选课轮次未开放时多为空表/提示）。
  /// 页面带学期日历时，按其学期 POST 查询出正式表格。
  Future<ElectPageView> electPage(String path) async {
    final html = await _fetch('$host$path');
    final calVal = RegExp(r'semesterCalendar\(\{[^}]*value:"(\d+)"')
        .firstMatch(html)
        ?.group(1);
    final notice =
        html.contains('当前不开放') ? '当前不开放' : null;

    var body = html;
    if (calVal != null) {
      try {
        final r2 = await dio.post('$host$path',
            data: {'semester.id': calVal, 'project.id': ''},
            options: Options(contentType: Headers.formUrlEncodedContentType));
        if (r2.statusCode == 200) body = r2.data as String;
      } catch (_) {}
    }

    final tables = <List<List<String>>>[];
    for (final tm in RegExp(r'<table[\s\S]*?</table>').allMatches(body)) {
      final rows = <List<String>>[];
      for (final rm in RegExp(r'<tr[\s\S]*?</tr>').allMatches(tm.group(0)!)) {
        final cells = RegExp(r'<t[dh][^>]*>([\s\S]*?)</t[dh]>')
            .allMatches(rm.group(0)!)
            .map((m) => m
                .group(1)!
                .replaceAll(RegExp(r'<[^>]+>'), '')
                .replaceAll(RegExp(r'&nbsp;'), ' ')
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim())
            .toList();
        // 只丢行首空单元格（勾选框列）；行中间的空位保留，否则后面所有列整体左移错列
        while (cells.isNotEmpty && cells.first.isEmpty) {
          cells.removeAt(0);
        }
        if (cells.isNotEmpty) rows.add(cells);
      }
      if (rows.length > 1) tables.add(rows); // 只有表头的空表不计
    }
    return ElectPageView(notice, tables);
  }

  /// 学期/学年绩点汇总（校方口径，含必修课平均绩点）
  Future<GradeSummary> historyGrade() async {
    final doc = html_parser.parse(await _fetch(
        '$host/eams/teach/grade/course/person!historyCourseGradeDetail.action'));
    final sems = <SemesterGpa>[];
    SemesterGpa? overall;
    final years = <YearGpa>[];
    for (final table in doc.querySelectorAll('table')) {
      final rows = table.querySelectorAll('tr');
      if (rows.isEmpty) continue;
      final header = rows.first.text;
      if (header.contains('学年度') && header.contains('平均绩点')) {
        final isYearTable = header.contains('学年门数');
        for (final tr in rows.skip(1)) {
          // 这张表的数据格也可能是 th，必须两种都抓；在校汇总行是 5 格（首格跨两列）
          final c = tr
              .querySelectorAll('th,td')
              .map((x) => x.text.trim())
              .toList();
          if (c.length < 5) continue;
          if (isYearTable) {
            years.add(YearGpa(c[0], int.tryParse(c[1]) ?? 0,
                double.tryParse(c[2]) ?? 0, double.tryParse(c[3]) ?? 0,
                double.tryParse(c[4]), double.tryParse(c[5])));
          } else if (c[0].contains('汇总')) {
            overall = SemesterGpa(c[0], '', int.tryParse(c[1]) ?? 0,
                double.tryParse(c[2]) ?? 0, double.tryParse(c[3]),
                double.tryParse(c[4]), isOverall: true);
          } else {
            sems.add(SemesterGpa(c[0], c[1], int.tryParse(c[2]) ?? 0,
                double.tryParse(c[3]) ?? 0, double.tryParse(c[4]),
                double.tryParse(c[5])));
          }
        }
      }
    }
    return GradeSummary(sems, overall, years);
  }

  /// 未中选课程（stdCourseTakeBin!search.action 的 bintable 网格）
  Future<List<CourseBinRecord>> courseTakeBin({String? semesterId}) async {
    final formHtml = await _fetch('$host/eams/stdCourseTakeBin.action');
    final sem = semesterId ??
        RegExp(r'semesterCalendar\(\{[^}]*value:"(\d+)"')
            .firstMatch(formHtml)
            ?.group(1) ??
        '';
    final res = await dio.post('$host/eams/stdCourseTakeBin!search.action',
        data: {'semester.id': sem, 'project.id': '1'},
        options: Options(contentType: Headers.formUrlEncodedContentType));
    final body = res.data as String;

    final doc = html_parser.parse(body);
    // 找到表头含「学号」的网格表
    const cols = [
      '学号', '姓名', '课程序号', '课程代码', '课程名称', '课程类别',
      '修读类别', '选课方式', '轮次', '组号', '选课状态', '货币值'
    ];
    List<int>? idx;
    final out = <CourseBinRecord>[];
    final seen = <String>{};
    for (final table in doc.querySelectorAll('table')) {
      for (final tr in table.querySelectorAll('tr')) {
        final cells =
            tr.querySelectorAll('th,td').map((c) => c.text.trim()).toList();
        if (cells.isEmpty) continue;
        if (idx == null) {
          final head = cells.skipWhile((c) => c.isEmpty).toList();
          if (head.contains('学号') && head.contains('课程序号')) {
            idx = [
              for (final col in cols) head.indexWhere((c) => c == col)
            ];
          }
          continue;
        }
        // 数据行：丢弃开头的空单元格（勾选框列），与表头位置对齐
        final vals = cells.skipWhile((c) => c.isEmpty).toList();
        if (vals.length < cols.length - 2) continue;
        String at(int i) => (i >= 0 && i < vals.length) ? vals[i] : '';
        final no = at(idx[2]);
        if (no.isEmpty || !seen.add(no)) continue;
        out.add(CourseBinRecord(
          at(idx[0]), at(idx[1]), no, at(idx[3]), at(idx[4]),
          at(idx[5]), at(idx[6]), at(idx[7]), at(idx[8]), at(idx[9]),
          at(idx[10]), at(idx[11]),
        ));
      }
      if (out.isNotEmpty) break; // 取到数据即停（页面里有重复网格副本）
    }
    return out;
  }

  /// 我的考试（examTable，allExamBatch 全批次，按学期过滤）。
  /// 服务端会把学期写进会话：切换学期必须先 POST examSearchForStd.action
  /// 设定学期（等同网页的"切换学期"按钮），再取表，否则会一直返回旧学期。
  Future<List<List<String>>> examTable({String? semesterId}) async {
    if (semesterId != null) {
      try {
        await dio.post('$host/eams/examSearchForStd.action',
            data: {'semester.id': semesterId, 'project.id': ''},
            options:
                Options(contentType: Headers.formUrlEncodedContentType));
      } catch (_) {}
    }
    final doc = html_parser.parse(await _fetch(
        '$host/eams/examSearchForStd!examTable.action?allExamBatch=1'));
    const cols = [
      '课程序号', '课程名称', '考试类别', '考试日期', '考试安排', '考试地点',
      '考场校区', '考场座位号', '考试情况', '其它说明'
    ];
    List<int>? idx;
    final rows = <List<String>>[];
    final seen = <String>{};
    for (final table in doc.querySelectorAll('table')) {
      for (final tr in table.querySelectorAll('tr')) {
        final cells =
            tr.querySelectorAll('th,td').map((c) => c.text.trim()).toList();
        if (cells.isEmpty) continue;
        if (idx == null) {
          final head = cells.skipWhile((c) => c.isEmpty).toList();
          if (head.contains('课程序号') && head.contains('考试日期')) {
            idx = [
              for (final col in cols) head.indexWhere((c) => c == col)
            ];
          }
          continue;
        }
        final vals = cells.skipWhile((c) => c.isEmpty).toList();
        if (vals.length < cols.length - 2) continue;
        String at(int i) => (i >= 0 && i < vals.length) ? vals[i] : '';
        final key = '${at(idx[0])}|${at(idx[3])}';
        if (at(idx[0]).isEmpty || !seen.add(key)) continue;
        rows.add([for (final col in cols) at(idx[cols.indexOf(col)])]);
      }
    }
    return rows;
  }
}
