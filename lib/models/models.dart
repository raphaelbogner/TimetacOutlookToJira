// lib/models/models.dart  (ERGÄNZT CSV-KONFIG)
class SettingsModel {
  String meetingIssueKey;
  String fallbackIssueKey;

  // Jira credentials
  String jiraBaseUrl;
  String jiraEmail;
  String jiraApiToken;

  // CSV-Konfiguration
  String csvDelimiter; // z. B. ";" oder ","
  bool csvHasHeader; // erste Zeile enthält Spaltennamen?
  String csvColDescription; // Spalte für "Beschreibung/Aktion" (optional)
  String csvColDate; // Spalte für Datum (yyyy-MM-dd)
  String csvColStart; // Spalte für Start (yyyy-MM-dd HH:mm:ss)
  String csvColEnd; // Spalte für Ende  (yyyy-MM-dd HH:mm:ss)
  String csvColDuration; // Spalte für Dauer (z. B. 7.50 oder 07:30) (optional)
  String csvColPauseTotal; // Spalte für Gesamtpausendauer an dem Tag
  String csvColPauseRanges; // Spalte für die einzelnen Pausen im Format ("10:00-10:15; 10:30-10:45")
  String csvColAbsenceTotal; // Spalte für Nichtarbeitszeit in Stunden
  String csvColSick; // Spalte für Krankenstand
  String csvColHoliday; // Spalte für Feiertag in Tagen (0.5 oder 1.0)
  String csvColVacation; // Spalte für Urlaubstag in Stunden
  String csvColTimeCompensation; // Spalte für Zeitausgleich in Stunden

  // GitLab
  String gitlabBaseUrl; // https://gitlab.example.com
  String gitlabToken; // PRIVATE-TOKEN
  String gitlabProjectIds; // Komma-/Leerzeichen-getrennt: "123, 456"
  String gitlabAuthorEmail; // optional: nur Commits dieser Mail
  int gitlabLookbackDays; // Lookback in Tagen, um „letztes Ticket“ vor dem Zeitraum zu finden

  // non meeting hints
  String nonMeetingHintsMultiline;

  // meeting title to ticket rules
  List<MeetingRule> meetingRules;

  // ---- Feste, unveränderliche Defaults (öffentlich) ----
  static const List<String> defaultNonMeetingHintsList = <String>[
    'homeoffice',
    'an anderem ort tätig',
    'im büro',
    'im office',
    'office',
    'büro',
    'arbeitsort',
    'arbeitsplatz',
    'standort',
    'working elsewhere',
    'focus',
    'focus time',
    'fokuszeit',
    'reise',
    'anreise',
    'commute',
    'fahrt',
    'fahrtzeit',
    'travel',
    'anwesenheit',
    'präsenz',
    'teilzeit',
    'weihnacht',
    'christmas',
    'save the date',
    'ski',
    'ausflug',
    'bbq',
    'grillen',
    'feier',
  ];

  SettingsModel({
    this.meetingIssueKey = '',
    this.fallbackIssueKey = '',
    this.jiraBaseUrl = '',
    this.jiraEmail = '',
    this.jiraApiToken = '',
    // Defaults für Timetac-Export
    this.csvDelimiter = ';',
    this.csvHasHeader = true,
    this.csvColDescription = 'Kommentar',
    this.csvColDate = 'Datum',
    this.csvColStart = 'K',
    this.csvColEnd = 'G',
    this.csvColDuration = 'GIBA',
    this.csvColPauseTotal = 'P',
    this.csvColPauseRanges = 'Pausen',
    this.csvColAbsenceTotal = 'BNA',
    this.csvColSick = 'KT',
    this.csvColHoliday = 'FT',
    this.csvColVacation = 'UT',
    this.csvColTimeCompensation = 'ZA',
    this.gitlabBaseUrl = '',
    this.gitlabToken = '',
    this.gitlabProjectIds = '',
    this.gitlabAuthorEmail = '',
    this.gitlabLookbackDays = 30,
    this.meetingRules = const [],
    String? nonMeetingHintsMultiline,
  }) : nonMeetingHintsMultiline = nonMeetingHintsMultiline ?? defaultNonMeetingHintsMultiline;

  static String get defaultNonMeetingHintsMultiline => defaultNonMeetingHintsList.join('\n');

  List<String> get nonMeetingHintsList => nonMeetingHintsMultiline
      .split(RegExp(r'\r?\n'))
      .map((e) => e.trim().toLowerCase())
      .where((e) => e.isNotEmpty)
      .toList();

  void restoreDefaultNonMeetingHints() {
    nonMeetingHintsMultiline = defaultNonMeetingHintsMultiline;
  }

  Map<String, dynamic> toJson() => {
        'meetingIssueKey': meetingIssueKey,
        'fallbackIssueKey': fallbackIssueKey,
        'jiraBaseUrl': jiraBaseUrl,
        'jiraEmail': jiraEmail,
        'jiraApiToken': jiraApiToken,
        'csvDelimiter': csvDelimiter,
        'csvHasHeader': csvHasHeader,
        'csvColDescription': csvColDescription,
        'csvColDate': csvColDate,
        'csvColStart': csvColStart,
        'csvColEnd': csvColEnd,
        'csvColDuration': csvColDuration,
        'csvColPauseTotal': csvColPauseTotal,
        'csvColPauseRanges': csvColPauseRanges,
        'csvColAbsenceTotal': csvColAbsenceTotal,
        'csvColSick': csvColSick,
        'csvColHoliday': csvColHoliday,
        'csvColVacation': csvColVacation,
        'csvColTimeCompensation': csvColTimeCompensation,
        'gitlabBaseUrl': gitlabBaseUrl,
        'gitlabToken': gitlabToken,
        'gitlabProjectIds': gitlabProjectIds,
        'gitlabAuthorEmail': gitlabAuthorEmail,
        'gitlabLookbackDays': gitlabLookbackDays,
        'nonMeetingHintsMultiline': nonMeetingHintsMultiline,
        'meetingRules': meetingRules.map((r) => r.toJson()).toList(),
      };

  factory SettingsModel.fromJson(Map<String, dynamic> m) => SettingsModel(
        meetingIssueKey: (m['meetingIssueKey'] ?? '').toString(),
        fallbackIssueKey: (m['fallbackIssueKey'] ?? '').toString(),
        jiraBaseUrl: (m['jiraBaseUrl'] ?? '').toString(),
        jiraEmail: (m['jiraEmail'] ?? '').toString(),
        jiraApiToken: (m['jiraApiToken'] ?? '').toString(),
        csvDelimiter: (m['csvDelimiter'] ?? ';').toString(),
        csvHasHeader: (m['csvHasHeader'] ?? false) as bool,
        csvColDescription: (m['csvColDescription'] ?? '').toString(),
        csvColDate: (m['csvColDate'] ?? '').toString(),
        csvColStart: (m['csvColStart'] ?? '').toString(),
        csvColEnd: (m['csvColEnd'] ?? '').toString(),
        csvColDuration: (m['csvColDuration'] ?? '').toString(),
        csvColPauseTotal: (m['csvColPauseTotal'] ?? '').toString(),
        csvColPauseRanges: (m['csvColPauseRanges'] ?? '').toString(),
        csvColAbsenceTotal: (m['csvColAbsenceTotal'] ?? '').toString(),
        csvColSick: (m['csvColSick'] ?? '').toString(),
        csvColHoliday: (m['csvColHoliday'] ?? '').toString(),
        csvColVacation: (m['csvColVacation'] ?? '').toString(),
        csvColTimeCompensation: (m['csvColTimeCompensation'] ?? '').toString(),
        gitlabBaseUrl: (m['gitlabBaseUrl'] ?? '').toString(),
        gitlabToken: (m['gitlabToken'] ?? '').toString(),
        gitlabProjectIds: (m['gitlabProjectIds'] ?? '').toString(),
        gitlabAuthorEmail: (m['gitlabAuthorEmail'] ?? '').toString(),
        gitlabLookbackDays: (m['gitlabLookbackDays'] ?? 30) is int
            ? m['gitlabLookbackDays'] as int
            : int.tryParse((m['gitlabLookbackDays'] ?? '30').toString()) ?? 30,
        nonMeetingHintsMultiline: (m['nonMeetingHintsMultiline'] ?? defaultNonMeetingHintsMultiline) as String,
        meetingRules: ((m['meetingRules'] as List?) ?? const [])
            .map((e) => MeetingRule.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

// Einfache Range für Pausen (damit kein Zirkelimport zu WorkWindow entsteht)
class TimeRange {
  TimeRange(this.start, this.end);
  DateTime start;
  DateTime end;
  Duration get duration => end.difference(start);
}

class TimetacRow {
  final String description;
  final DateTime date; // day-only
  final DateTime? start; // optional
  final DateTime? end; // optional
  final Duration duration; // preferred from start/end
  final Duration pauseTotal;
  final List<TimeRange> pauses;
  final Duration absenceTotal; // Arzttermine in Stunden (nur wenn KT/FT/UT = 0), ansonsten alles gesamt
  final double sickDays;
  final double holidayDays;
  final Duration vacationHours;
  final Duration timeCompensationHours;

  TimetacRow({
    required this.description,
    required this.date,
    required this.start,
    required this.end,
    required this.duration,
    this.pauseTotal = Duration.zero,
    this.absenceTotal = Duration.zero,
    this.sickDays = 0.0,
    this.holidayDays = 0.0,
    this.vacationHours = Duration.zero,
    this.timeCompensationHours = Duration.zero,
    List<TimeRange>? pauses,
  }) : pauses = pauses ?? const [];
}

class DayTotals {
  final DateTime date;
  final Duration timetacTotal;
  final Duration meetingsTotal;
  final Duration leftover;
  final double sickDays;
  final double holidayDays;
  final Duration vacationHours;
  final Duration timeCompensationHours;
  final Duration doctorHours;

  DayTotals({
    required this.date,
    required this.timetacTotal,
    required this.meetingsTotal,
    required this.leftover,
    required this.sickDays,
    required this.holidayDays,
    required this.vacationHours,
    required this.timeCompensationHours,
    required this.doctorHours,
  });
}

class MeetingRule {
  MeetingRule({
    required this.pattern,
    required this.issueKey,
  });

  String pattern; // z. B. "1:1", "Code Review"
  String issueKey; // z. B. "MGMT-123"

  factory MeetingRule.fromJson(Map<String, dynamic> json) => MeetingRule(
        pattern: (json['pattern'] ?? '') as String,
        issueKey: (json['issueKey'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'pattern': pattern,
        'issueKey': issueKey,
      };
}
