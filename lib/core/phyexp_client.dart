// Engine | Flutter 3.x / Dart 3 | lib/core/phyexp_client.dart
// 物理实验预约系统客户端（phyexp.nuaa.edu.cn，将军路 /api 口径；
// 天目湖为 /tianmuhu/api、应用物理为 /yywlx/api，同构）。
// 链路全部实测（2026-09-29 真实预约通过）：
//   1. 登录 POST rest/rpc/login（form: code + MD5(password)）-> JWT
//   2. GET rest/semesters?is_open=eq.true -> 开放学期（since/to）
//   3. GET rest/groupusers?semester_id=&student_id= -> class_id/course_id
//   4. GET rest/course2projects?...&course_id= -> 实验项目（projects 内嵌）
//   5. GET rest/user2projects?...schedule_status=in.(elected,...) -> 已选
//   6. GET rest/schedules?...project_id=&date=gte/to -> 场次（容量/余量）
//   7. 选课 POST report-api/electives（form: lesson_id + course_id）-> 200 成功
// JWT 存 flutter_secure_storage；401 时若存有密码自动重登一次。
// Deps: dio, crypto, flutter_secure_storage

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const phyexpOrigin = 'https://phyexp.nuaa.edu.cn';
const phyexpApiBase = '$phyexpOrigin/api';

class PhyExpUser {
  final String token; // 原始 JWT（不带 Bearer 前缀）
  final int userId;
  final String code;
  final String name;

  const PhyExpUser({
    required this.token,
    required this.userId,
    required this.code,
    required this.name,
  });
}

/// 开放学期
class PhyExpSemester {
  final int id;
  final String name;
  final DateTime since;
  final DateTime to;

  const PhyExpSemester(this.id, this.name, this.since, this.to);
}

/// 一门物理实验课（分组信息里带 class_id 与课程名）
class PhyExpCourse {
  final int courseId;
  final String courseName;
  final int semesterId;
  final int classId;
  final String className;

  const PhyExpCourse(
    this.courseId,
    this.courseName,
    this.semesterId,
    this.classId,
    this.className,
  );
}

/// 实验项目
class PhyExpExperiment {
  final int projectId;
  final String name;
  final bool optional; // 选修？
  final bool elected; // 我已选（任意场次）

  const PhyExpExperiment(
    this.projectId,
    this.name, {
    required this.optional,
    required this.elected,
  });
}

/// 场次
class PhyExpLesson {
  final int scheduleId;
  final String date; // 2026-10-08
  final String periodName; // 上午1、2节
  final String startTime; // 08:00:00
  final String endTime; // 09:45:00
  final String location;
  final String teacher;
  final int maxStudent;
  final int currentStudent;
  final bool bookedByMe;
  final int? user2projectId; // 已选时非空，退课接口用

  const PhyExpLesson({
    required this.scheduleId,
    required this.date,
    required this.periodName,
    required this.startTime,
    required this.endTime,
    required this.location,
    required this.teacher,
    required this.maxStudent,
    required this.currentStudent,
    required this.bookedByMe,
    this.user2projectId,
  });

  int get remaining =>
      (maxStudent - currentStudent).clamp(0, maxStudent).toInt();

  DateTime get start => DateTime.parse('${date}T$startTime');
}

/// 已选的实验（我的实验列表条目）
class PhyExpMyExperiment {
  final int user2projectId;
  final String name;
  final String date;
  final String periodName;
  final String startTime;
  final String endTime;
  final String location;
  final String teacher;
  final String status; // elected / scheduled / free_schedule

  const PhyExpMyExperiment({
    required this.user2projectId,
    required this.name,
    required this.date,
    required this.periodName,
    required this.startTime,
    required this.endTime,
    required this.location,
    required this.teacher,
    required this.status,
  });

  DateTime get start =>
      DateTime.tryParse('${date}T$startTime') ?? DateTime(1970);

  String get statusText => switch (status) {
    'elected' => '已选',
    'scheduled' => '已排课',
    'free_schedule' => '自由排课',
    _ => status,
  };
}

class PhyExpClient {
  PhyExpClient._();
  static final instance = PhyExpClient._();

  static const _storage = FlutterSecureStorage();
  static const _kToken = 'phyexp_token';
  static const _kUserId = 'phyexp_user_id';
  static const _kCode = 'phyexp_code';
  static const _kName = 'phyexp_name';
  static const _kPassword = 'phyexp_password'; // 记住密码时才存

  Dio? _dio;
  PhyExpUser? user;
  String? savedPassword; // 记住密码：401 自动重登

  bool get loggedIn => user != null;

  Dio get dio => _dio ??= Dio(
    BaseOptions(
      baseUrl: phyexpApiBase,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      headers: {'User-Agent': 'i-niuaa'},
    ),
  );

  /// 恢复登录态
  Future<bool> restore() async {
    try {
      final token = await _storage.read(key: _kToken);
      final uid = await _storage.read(key: _kUserId);
      final code = await _storage.read(key: _kCode);
      final name = await _storage.read(key: _kName);
      savedPassword = await _storage.read(key: _kPassword);
      if (token == null || uid == null) return false;
      user = PhyExpUser(
        token: token,
        userId: int.parse(uid),
        code: code ?? '',
        name: name ?? '',
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 登录：code + MD5(password) -> JWT。[remember] 为真时保存密码用于 401 重登
  Future<void> login(
    String code,
    String password, {
    bool remember = true,
  }) async {
    final md5pwd = md5.convert(utf8.encode(password)).toString();
    final res = await dio.post(
      '/rest/rpc/login',
      data: 'code=$code&password=$md5pwd',
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    final data = res.data;
    if (res.statusCode != 200 || data is! Map || data['token'] == null) {
      throw Exception('登录失败：账号或密码错误');
    }
    user = PhyExpUser(
      token: data['token'] as String,
      userId: (data['id'] as num).toInt(),
      code: (data['code'] ?? code).toString(),
      name: (data['name'] ?? '').toString(),
    );
    await _storage.write(key: _kToken, value: user!.token);
    await _storage.write(key: _kUserId, value: '${user!.userId}');
    await _storage.write(key: _kCode, value: user!.code);
    await _storage.write(key: _kName, value: user!.name);
    if (remember) {
      savedPassword = password;
      await _storage.write(key: _kPassword, value: password);
    } else {
      savedPassword = null;
      await _storage.delete(key: _kPassword);
    }
  }

  Future<void> logout() async {
    user = null;
    savedPassword = null;
    for (final k in [_kToken, _kUserId, _kCode, _kName, _kPassword]) {
      await _storage.delete(key: k);
    }
  }

  Options _auth() =>
      Options(headers: {'Authorization': 'Bearer ${user!.token}'});

  /// 用记住的密码重登并刷新 token；失败抛异常
  Future<void> _relogin() async {
    final res = await dio.post(
      '/rest/rpc/login',
      data:
          'code=${user!.code}&password=${md5.convert(utf8.encode(savedPassword!))}',
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    if (res.statusCode == 200 && res.data is Map && res.data['token'] != null) {
      user = PhyExpUser(
        token: res.data['token'] as String,
        userId: user!.userId,
        code: user!.code,
        name: user!.name,
      );
      await _storage.write(key: _kToken, value: user!.token);
    } else {
      throw Exception('重新登录失败');
    }
  }

  /// 带鉴权请求；401 且存有密码时重登一次再试。
  /// [fn] 接收挂好 Authorization 的 Options，自行决定校验与取值
  Future<dynamic> _authed(
    Future<Response<dynamic>> Function(Options o) fn,
  ) async {
    try {
      final res = await fn(_auth());
      return res.data;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401 &&
          savedPassword != null &&
          user != null) {
        await _relogin();
        final res = await fn(_auth());
        return res.data;
      }
      rethrow;
    }
  }

  /// 带鉴权 GET
  Future<dynamic> _get(String path, {Map<String, dynamic>? query}) =>
      _authed((o) => dio.get(path, queryParameters: query, options: o));

  /// 开放学期（取第一个；含 since/to）
  Future<PhyExpSemester> openSemester() async {
    final list = await _get('/rest/semesters', query: {'is_open': 'eq.true'});
    if (list is! List || list.isEmpty) {
      throw Exception('当前没有开放的学期');
    }
    final j = list.first as Map;
    return PhyExpSemester(
      (j['id'] as num).toInt(),
      (j['name'] ?? '').toString(),
      DateTime.parse('${j['since']}'),
      DateTime.parse('${j['to']}'),
    );
  }

  /// 我的实验课（通常一门；取分组信息里的 course/class）
  Future<List<PhyExpCourse>> myCourses(int semesterId, int userId) async {
    final list = await _get(
      '/rest/groupusers',
      query: {'semester_id': 'eq.$semesterId', 'student_id': 'eq.$userId'},
    );
    if (list is! List) return const [];
    final seen = <int>{};
    final out = <PhyExpCourse>[];
    for (final j in list.whereType<Map>()) {
      final cid = (j['course_id'] as num?)?.toInt();
      if (cid == null || !seen.add(cid)) continue;
      out.add(
        PhyExpCourse(
          cid,
          (j['course_name'] ?? '').toString(),
          semesterId,
          (j['class_id'] as num?)?.toInt() ?? 0,
          (j['class_name'] ?? '').toString(),
        ),
      );
    }
    return out;
  }

  /// 课程下的实验项目。[electedProjectIds] 用于标记"我已选"
  Future<List<PhyExpExperiment>> experiments(
    int courseId,
    Set<int> electedProjectIds,
  ) async {
    final list = await _get(
      '/rest/course2projects',
      query: {
        'select':
            'course_id,project_id,optional,group,free_schedule,projects(*)',
        'course_id': 'eq.$courseId',
      },
    );
    if (list is! List) return const [];
    final out = <PhyExpExperiment>[];
    for (final j in list.whereType<Map>()) {
      final p = j['projects'];
      if (p is! Map) continue;
      final pid = (p['id'] as num).toInt();
      out.add(
        PhyExpExperiment(
          pid,
          (p['name'] ?? '').toString(),
          optional: j['optional'].toString() == 'true',
          elected: electedProjectIds.contains(pid),
        ),
      );
    }
    return out;
  }

  /// 我已选的（experiment -> project_id 集合）
  Future<Set<int>> electedProjectIds(
    int semesterId,
    int userId,
    int courseId,
  ) async {
    final list = await _get(
      '/rest/user2projects',
      query: {
        'semester_id': 'eq.$semesterId',
        'user_id': 'eq.$userId',
        'course_id': 'eq.$courseId',
        'schedule_status': 'in.(elected,scheduled,free_schedule)',
        'select': 'project_id,schedule_id,schedule_status',
      },
    );
    final out = <int>{};
    if (list is List) {
      for (final j in list.whereType<Map>()) {
        final pid = (j['project_id'] as num?)?.toInt();
        if (pid != null) out.add(pid);
      }
    }
    return out;
  }

  /// 某实验的场次（按学期起止取已发布的排课；user2projects 内嵌非空 = 我已选该场）
  Future<List<PhyExpLesson>> lessons({
    required int projectId,
    required int courseId,
    required int userId,
    required int classId,
    required PhyExpSemester semester,
  }) async {
    final list = await _get(
      '/rest/schedules',
      query: {
        // 学期起止（实测口径不带前导零）；手工过滤兜底
        'select':
            '*,periods(name,start_time,end_time),locations(name),teacher:users!schedule_teacher_id_fkey(name),user2projects!user2project_schedule_id_fkey(id)',
        'is_publish': 'eq.true',
        'project_id': 'eq.$projectId',
        // 两个 or 条件都要发（dio 对 List 值会拼成 or=(..)&or=(..)）
        'or': [
          '(course_id.is.null,course_id.eq.$courseId)',
          '(is_reserved.eq.false,class_list.cs.{$classId},class_list.cs.{null})',
        ],
        'user2projects.user_id': 'eq.$userId',
        'user2projects.schedule_status': 'in.(elected,scheduled)',
        'date': [
          'gte.${_shortDate(semester.since)}',
          'lte.${_shortDate(semester.to)}',
        ],
      },
    );
    final since = DateTime(
      semester.since.year,
      semester.since.month,
      semester.since.day,
    );
    final until = semester.to.add(const Duration(days: 1));
    final out = <PhyExpLesson>[];
    if (list is List) {
      for (final j in list.whereType<Map>()) {
        // 日期范围兜底：必须用真日期解析，字符串比较会因位数错序
        final date = (j['date'] ?? '').toString();
        final d = DateTime.tryParse(date);
        if (d == null || d.isBefore(since) || d.isAfter(until)) continue;
        final period = (j['periods'] as Map?) ?? const {};
        final loc = (j['locations'] as Map?) ?? const {};
        final teacher = (j['teacher'] as Map?) ?? const {};
        out.add(
          PhyExpLesson(
            scheduleId: (j['id'] as num).toInt(),
            date: date,
            periodName: (period['name'] ?? '').toString(),
            startTime: (period['start_time'] ?? '').toString(),
            endTime: (period['end_time'] ?? '').toString(),
            location: (loc['name'] ?? '').toString(),
            teacher: (teacher['name'] ?? '').toString(),
            maxStudent: (j['max_student_number'] as num?)?.toInt() ?? 0,
            currentStudent: (j['current_student_number'] as num?)?.toInt() ?? 0,
            bookedByMe: ((j['user2projects'] as List?) ?? const []).isNotEmpty,
            user2projectId: ((j['user2projects'] as List?) ?? const [])
                .whereType<Map>()
                .map((x) => (x['id'] as num?)?.toInt())
                .firstWhere((x) => x != null, orElse: () => null),
          ),
        );
      }
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  /// 我的实验：已选记录（含场次日期/节次/地点/老师/状态）
  Future<List<PhyExpMyExperiment>> myExperiments(
    int semesterId,
    int userId,
    int courseId,
  ) async {
    final list = await _get(
      '/rest/user2projects',
      query: {
        'select':
            'id,project_id,schedule_id,schedule_status,'
            'schedules!user2project_schedule_id_fkey(date,periods(name,start_time,end_time),locations(name),teacher:users!schedule_teacher_id_fkey(name)),'
            'projects!user2project_project_id_fkey(name)',
        'semester_id': 'eq.$semesterId',
        'user_id': 'eq.$userId',
        'course_id': 'eq.$courseId',
        'schedule_status': 'in.(elected,scheduled,free_schedule)',
      },
    );
    final out = <PhyExpMyExperiment>[];
    if (list is! List) return out;
    for (final j in list.whereType<Map>()) {
      final project = (j['projects'] as Map?) ?? const {};
      final sched = (j['schedules'] as Map?) ?? const {};
      final period = (sched['periods'] as Map?) ?? const {};
      final loc = (sched['locations'] as Map?) ?? const {};
      final teacher = (sched['teacher'] as Map?) ?? const {};
      out.add(
        PhyExpMyExperiment(
          user2projectId: (j['id'] as num?)?.toInt() ?? 0,
          name: (project['name'] ?? '').toString(),
          date: (sched['date'] ?? '').toString(),
          periodName: (period['name'] ?? '').toString(),
          startTime: (period['start_time'] ?? '').toString(),
          endTime: (period['end_time'] ?? '').toString(),
          location: (loc['name'] ?? '').toString(),
          teacher: (teacher['name'] ?? '').toString(),
          status: (j['schedule_status'] ?? '').toString(),
        ),
      );
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  /// 选课（实测口径：form lesson_id + course_id，200 即成功）
  Future<void> book(int lessonId, int courseId) async {
    final body = await _authed(
      (o) => dio.post(
        '/report-api/electives',
        data: 'lesson_id=$lessonId&course_id=$courseId',
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: o.headers,
          validateStatus: (s) => s != null && s < 500,
        ),
      ),
    );
    if (body is Map && body['message'] != null) {
      final msg = body['message'].toString();
      if (msg.contains('失败') || msg.contains('已满') || msg.contains('错误')) {
        throw Exception(msg);
      }
    }
  }

  /// 退课（实测口径：POST report-api/electives/`<user2project_id>`/cancel，
  /// 无请求体；响应 `{"status":false,"code":200,"message":"ok"}` 但退课成功）
  Future<void> cancel(int user2projectId) async {
    final res = await _authed(
      (o) => dio.post(
        '/report-api/electives/$user2projectId/cancel',
        options: Options(
          headers: o.headers,
          validateStatus: (s) => s != null && s < 500,
        ),
      ),
    );
    if (res.statusCode != 200) {
      throw Exception('退课失败（HTTP ${res.statusCode}）');
    }
  }

  String _shortDate(DateTime d) =>
      '${d.year}-${d.month}-${d.day}'; // PostgREST 接受不带前导零（实测口径）
}
