// Engine | Flutter 3.x / Dart 3 | lib/core/models.dart
// 纯数据模型；CourseSpan 带周次解析和 JSON 序列化（本地缓存用）

class Semester {
  final String id;
  final String name;
  const Semester(this.id, this.name);
}

/// 课表里一门课的连续时段：周[weekday]（1=周一）第 [startUnit]..[endUnit]
/// 单元（0 起、含端点；4/5 为午一午二，一般不占）。跨 N 节的课归并为一个时段。
class CourseSpan {
  final String name, teacher, weeks, room;
  final int weekday, startUnit, endUnit;

  CourseSpan(this.name, this.teacher, this.weeks, this.room, this.weekday,
      {required this.startUnit, int? endUnit})
      : endUnit = endUnit ?? startUnit;

  Set<int> get weekSet => parseWeeks(weeks);

  int get durationUnits => endUnit - startUnit + 1;

  /// "6-16,18" -> {6..16, 18}；解析不了的串返回空集（显示时视为全周次）
  static Set<int> parseWeeks(String s) {
    final out = <int>{};
    for (final part in s.split(',')) {
      final m = RegExp(r'^(\d+)(?:-(\d+))?$').firstMatch(part.trim());
      if (m == null) continue;
      final a = int.parse(m.group(1)!);
      final b = int.parse(m.group(2) ?? m.group(1)!);
      for (var i = a; i <= b; i++) {
        out.add(i);
      }
    }
    return out;
  }

  Map<String, dynamic> toJson() =>
      {'n': name, 't': teacher, 'w': weeks, 'r': room, 'd': weekday,
       's': startUnit, 'e': endUnit};

  factory CourseSpan.fromJson(Map<String, dynamic> j) => CourseSpan(
        j['n'] as String,
        j['t'] as String? ?? '',
        j['w'] as String? ?? '',
        j['r'] as String? ?? '',
        j['d'] as int,
        startUnit: j['s'] as int,
        endUnit: j['e'] as int?,
      );
}

/// 课程列表里的一门课（courseTable POST 页面的"课程列表"表）
class CourseListItem {
  final String seq, code, name, category, credit, teacher, teachClass;
  CourseListItem(this.seq, this.code, this.name, this.category, this.credit,
      this.teacher, this.teachClass);
  Map<String, dynamic> toJson() =>
      {'s': seq, 'c': code, 'n': name, 'k': category, 'r': credit, 't': teacher, 'g': teachClass};
  factory CourseListItem.fromJson(Map<String, dynamic> j) => CourseListItem(
      j['s'] as String? ?? '',
      j['c'] as String? ?? '',
      j['n'] as String? ?? '',
      j['k'] as String? ?? '',
      j['r'] as String? ?? '',
      j['t'] as String? ?? '',
      j['g'] as String? ?? '');
}

/// 课表整体（学期名 + 当前学期 id + 全部学期 + 时段列表 + 当前教学周 + 课程列表）
class CourseTableData {
  final String semesterName;
  final String semesterId;
  final List<Semester> semesters;
  final List<CourseSpan> spans;
  final int? currentWeek;
  final List<CourseListItem> courseList;
  CourseTableData(this.semesterName, this.semesterId, this.semesters,
      this.spans, this.currentWeek, this.courseList);
}

/// 一条成绩（person-grade.action 一页返回全部学期）
class GradeEntry {
  final String semester, name, category;
  final double credit;
  final double? gotCredit, score, gp;
  const GradeEntry(this.semester, this.name, this.category, this.credit,
      this.gotCredit, this.score, this.gp);
}

class ExamBatch {
  final String id, name;
  const ExamBatch(this.id, this.name);
}

class ExamCourse {
  final String courseNo, name, dept, credit;
  const ExamCourse(this.courseNo, this.name, this.dept, this.credit);
}

/// 补选/重修目录里的一门课
class ElectiveCourse {
  final String id, no, name, teachers, teachClassName, campusName,
      courseTypeName, stdCount, limitCount;
  final double credits;
  final List<String> timeDigests;
  ElectiveCourse(
      this.id, this.no, this.name, this.teachers, this.teachClassName,
      this.campusName, this.courseTypeName, this.stdCount, this.limitCount,
      this.credits, this.timeDigests);
}

/// 通用页面视图：提示语 + 解析出来的表格（行→列）
class ElectPageView {
  final String? notice;
  final List<List<List<String>>> tables;
  ElectPageView(this.notice, this.tables);
}

/// 学期选课轮次里的一门课（stdElectCourse!data.action）
class ElectLesson {
  final String id, name, code, teachers; // code/teachers 可能缺，为空则 UI 不显示
  const ElectLesson(this.id, this.name, this.code, this.teachers);
}

/// 一次 batchOperator 提交的判定（与 Xuanke_v2 的关键词判定同口径）
enum ElectVerdict { ok, rateLimited, fail, neutral }

/// 一次 batchOperator 提交的结果
class ElectSubmitResult {
  final int status;
  final String message;
  final ElectVerdict verdict;
  const ElectSubmitResult(this.status, this.message, this.verdict);
}

/// 未中选课程记录（stdCourseTakeBin!search.action）
class CourseBinRecord {
  final String studentNo, studentName, courseNo, courseCode, courseName,
      category, takeType, electWay, round, groupNo, status, currency;
  CourseBinRecord(this.studentNo, this.studentName, this.courseNo,
      this.courseCode, this.courseName, this.category, this.takeType,
      this.electWay, this.round, this.groupNo, this.status, this.currency);
}

/// 学期绩点（校方口径，historyCourseGradeDetail）
class SemesterGpa {
  final String year, term;
  final int count;
  final double credits;
  final double? gpa, reqGpa;
  final bool isOverall;
  SemesterGpa(this.year, this.term, this.count, this.credits, this.gpa,
      this.reqGpa, {this.isOverall = false});
}

/// 学年绩点汇总
class YearGpa {
  final String year;
  final int count;
  final double credits, reqCredits;
  final double? gpa, reqGpa;
  YearGpa(this.year, this.count, this.credits, this.reqCredits, this.gpa, this.reqGpa);
}

/// 绩点汇总（学期明细 + 在校汇总 + 学年统计）
class GradeSummary {
  final List<SemesterGpa> semesters;
  final SemesterGpa? overall;
  final List<YearGpa> years;
  GradeSummary(this.semesters, this.overall, this.years);
}

/// 卡片充值页的卡户信息（queryCard 首张实体卡；余额分转元）
class RechargeAccount {
  final String name, account, cardName, cardType;
  final double balanceYuan;
  final bool lostFlag;
  const RechargeAccount({
    required this.name,
    required this.account,
    required this.cardName,
    required this.cardType,
    required this.balanceYuan,
    required this.lostFlag,
  });
}

/// 一卡通付款码批次：服务端一次下发 [codes]，第 i 个码在拉取后
/// [expiresSeconds]*(i+1) 秒内有效（第 0 个管 0..expires，第 1 个管
/// expires..2*expires ……），到点切换下一个，全部用完需重新拉取。
class PayCodeBatch {
  final List<String> codes;
  final int expiresSeconds;
  final DateTime fetchedAt;
  PayCodeBatch({
    required this.codes,
    required this.expiresSeconds,
    DateTime? fetchedAt,
  }) : fetchedAt = fetchedAt ?? DateTime.now();

  factory PayCodeBatch.fromJson(Map<String, dynamic> j) => PayCodeBatch(
        codes: (j['c'] as List? ?? []).cast<String>(),
        expiresSeconds: j['x'] as int? ?? 120,
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(j['t'] as int? ?? 0),
      );

  Map<String, dynamic> toJson() => {
        'c': codes,
        'x': expiresSeconds,
        't': fetchedAt.millisecondsSinceEpoch,
      };

  /// [now] 时应出示的码下标；空批次 / 时钟回拨 / 全部用完返回 -1
  int indexAt(DateTime now) {
    if (codes.isEmpty || expiresSeconds <= 0) return -1;
    final elapsed = now.difference(fetchedAt).inSeconds;
    if (elapsed < 0) return 0; // 本机时钟略慢，视为仍在第 0 个窗口
    final i = elapsed ~/ expiresSeconds;
    return i < codes.length ? i : -1;
  }

  /// 当前码距窗口结束的剩余秒数（倒计时用）；无有效码返回 0
  int secondsLeftAt(DateTime now) {
    final i = indexAt(now);
    if (i < 0) return 0;
    return expiresSeconds * (i + 1) - now.difference(fetchedAt).inSeconds;
  }

  /// [now] 时应出示的码；无有效码返回 null
  String? codeAt(DateTime now) {
    final i = indexAt(now);
    return i < 0 ? null : codes[i];
  }
}
