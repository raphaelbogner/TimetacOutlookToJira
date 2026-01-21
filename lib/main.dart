import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'logic/worklog_builder.dart';
import 'models/models.dart';
import 'services/csv_parser.dart';
import 'services/gitlab_api.dart';
import 'services/ics_parser.dart';
import 'services/jira_api.dart';
import 'services/jira_worklog_api.dart';
import 'services/delete_mode_service.dart';
import 'services/jira_adjustment_service.dart';
import 'services/time_comparison_service.dart';
import 'ui/delete_mode_screen.dart';
import 'ui/preview_utils.dart';
import 'widgets/preview_table.dart';
import 'widgets/draft_log_tile.dart';
import 'services/title_replacement_service.dart';
import 'services/update_service.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('de_DE', null);
  Intl.defaultLocale = 'de_DE';
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState()..loadPrefs(),
      child: Builder(
        builder: (context) {
          final app = context.watch<AppState>();
          final light = ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey, brightness: Brightness.light),
            useMaterial3: true,
          );
          final dark = ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey, brightness: Brightness.dark),
            useMaterial3: true,
          );
          return MaterialApp(
            title: 'Chronos',
            theme: light,
            darkTheme: dark,
            themeMode: app.themeMode,
            debugShowCheckedModeBanner: false,
            locale: const Locale('de', 'DE'),
            supportedLocales: const [
              Locale('de', 'DE'),
              Locale('en', 'US'),
            ],
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: const HomePage(),
          );
        },
      ),
    );
  }
}

class AppState extends ChangeNotifier {
  SettingsModel settings = SettingsModel();
  List<TimetacRow> timetac = [];
  List<IcsEvent> icsEvents = [];
  List<JiraWorklog> _existingWorklogs = [];

  bool _jiraAuthOk = false;
  bool _gitlabAuthOk = false;
  bool deltaModeEnabled = true;

  bool get hasCsv => timetac.isNotEmpty;
  bool get hasIcs => icsEvents.isNotEmpty;
  bool get jiraAuthOk => _jiraAuthOk;
  bool get gitlabAuthOk => _gitlabAuthOk;
  List<JiraWorklog> get existingWorklogs => _existingWorklogs;

  // GitLab Cache
  List<GitlabCommit> gitlabCommits = [];

  DateTimeRange? range;
  Set<DateTime> selectedDates = {};  // For individual day selection
  bool dateSelectionRangeMode = true; // true = range, false = individual days
  
  /// Returns the effective selected dates based on the current mode
  Set<DateTime> get effectiveSelectedDates {
    if (dateSelectionRangeMode && range != null) {
      final dates = <DateTime>{};
      var d = range!.start;
      while (!d.isAfter(range!.end)) {
        dates.add(DateTime(d.year, d.month, d.day));
        d = d.add(const Duration(days: 1));
      }
      return dates;
    } else {
      return selectedDates;
    }
  }
  
  String? jiraAccountId;

  // ---- Theme ----
  ThemeMode themeMode = ThemeMode.light;
  bool get isDark => themeMode == ThemeMode.dark;
  void toggleTheme() {
    themeMode = isDark ? ThemeMode.light : ThemeMode.dark;
    _saveThemePref();
    notifyListeners();
  }

  Future<void> loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    final jsonStr = p.getString('settings');
    if (jsonStr != null) {
      try {
        settings = SettingsModel.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
      } catch (_) {}
    }
    _normalizeUrlsInSettings();

    final tm = p.getString('themeMode');
    if (tm == 'dark') themeMode = ThemeMode.dark;
    if (tm == 'light') themeMode = ThemeMode.light;

    notifyListeners();

    // Auto-Check beim Start
    if (_jiraFieldsFilled) {
      await validateJiraCredentials();
    } else {
      _jiraAuthOk = false;
      notifyListeners();
    }

    if (_gitlabFieldsFilled || settings.noGitlabAccount) {
      await validateGitlabCredentials();
    } else {
      _gitlabAuthOk = false;
      notifyListeners();
    }
  }

  Future<bool> validateJiraCredentials({bool requireTickets = true}) async {
    final credsOk = _jiraCredentialFieldsFilled;
    final ticketsOk = _jiraTicketFieldsFilled;

    // Wenn Zugangsdaten fehlen → gar nicht erst gegen Jira schießen
    // Wenn requireTickets=true, müssen zusätzlich die Tickets gefüllt sein.
    if (!credsOk || (requireTickets && !ticketsOk)) {
      _jiraAuthOk = false;
      jiraAccountId = null;
      notifyListeners();
      return false;
    }

    try {
      final api = JiraApi(
        baseUrl: settings.jiraBaseUrl,
        email: settings.jiraEmail,
        apiToken: settings.jiraApiToken,
      );

      final ok = await api.checkAuth();
      _jiraAuthOk = ok;

      if (ok) {
        jiraAccountId = await api.fetchMyAccountId();
      } else {
        jiraAccountId = null;
      }

      notifyListeners();
      return ok;
    } catch (_) {
      _jiraAuthOk = false;
      jiraAccountId = null;
      notifyListeners();
      return false;
    }
  }

  void markJiraUnknown() {
    _jiraAuthOk = false;
    notifyListeners();
  }

  Future<bool> validateGitlabCredentials() async {
    if (settings.noGitlabAccount) {
      _gitlabAuthOk = true;
      notifyListeners();
      return true;
    }

    if (!_gitlabFieldsFilled) {
      _gitlabAuthOk = false;
      notifyListeners();
      return false;
    }
    try {
      final api = GitlabApi(
        baseUrl: settings.gitlabBaseUrl,
        token: settings.gitlabToken,
      );
      final ok = await api.checkAuth();
      _gitlabAuthOk = ok;
      notifyListeners();
      return ok;
    } catch (_) {
      _gitlabAuthOk = false;
      notifyListeners();
      return false;
    }
  }

  void markGitlabUnknown() {
    _gitlabAuthOk = false;
    notifyListeners();
  }

  Future<void> savePrefs() async {
    _normalizeUrlsInSettings();
    final p = await SharedPreferences.getInstance();
    await p.setString('settings', jsonEncode(settings.toJson()));
    await _saveThemePref();
    notifyListeners();
  }

  Future<void> _saveThemePref() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('themeMode', themeMode == ThemeMode.dark ? 'dark' : 'light');
  }

  String _normalizeBaseUrl(String input) {
    var s = input.trim();
    if (s.isEmpty) return '';
    if (!s.toLowerCase().startsWith('http://') && !s.toLowerCase().startsWith('https://')) {
      s = 'https://$s';
    }
    Uri? u;
    try {
      u = Uri.parse(s);
    } catch (_) {
      return s.replaceAll(RegExp(r'/+$'), ''); // Fallback: nur Slashes kappen
    }
    if ((u.host).isEmpty) return s.replaceAll(RegExp(r'/+$'), '');

    // Pfad ohne abschließenden Slash lassen, Query/Fragment verwerfen
    var path = u.path.replaceAll(RegExp(r'/+$'), '');
    final portPart = (u.hasPort && u.port != 443) ? ':${u.port}' : '';
    final pathPart = path.isEmpty ? '' : (path.startsWith('/') ? path : '/$path');

    return 'https://${u.host.toLowerCase()}$portPart$pathPart';
  }

  void _normalizeUrlsInSettings() {
    settings.jiraBaseUrl = _normalizeBaseUrl(settings.jiraBaseUrl);
    settings.gitlabBaseUrl = _normalizeBaseUrl(settings.gitlabBaseUrl);
  }

  // ---------- Konfig-Validierung ----------
  bool get _jiraCredentialFieldsFilled =>
      settings.jiraBaseUrl.trim().isNotEmpty &&
      settings.jiraEmail.trim().isNotEmpty &&
      settings.jiraApiToken.trim().isNotEmpty;

  bool get _jiraTicketFieldsFilled =>
      settings.meetingIssueKey.trim().isNotEmpty &&
      settings.fallbackIssueKey.trim().isNotEmpty;

  bool get _jiraFieldsFilled => _jiraCredentialFieldsFilled && _jiraTicketFieldsFilled;

  bool get isJiraConfigured => _jiraFieldsFilled && _jiraAuthOk;

  bool get isTimetacConfigured =>
      settings.csvDelimiter.trim().isNotEmpty &&
      settings.csvColDate.trim().isNotEmpty &&
      settings.csvColStart.trim().isNotEmpty &&
      settings.csvColEnd.trim().isNotEmpty &&
      settings.csvColDescription.trim().isNotEmpty &&
      settings.csvColPauseTotal.trim().isNotEmpty &&
      settings.csvColPauseRanges.trim().isNotEmpty &&
      settings.csvColAbsenceTotal.trim().isNotEmpty &&
      settings.csvColSick.trim().isNotEmpty &&
      settings.csvColHoliday.trim().isNotEmpty &&
      settings.csvColVacation.trim().isNotEmpty &&
      settings.csvColTimeCompensation.trim().isNotEmpty;

  bool get _gitlabFieldsFilled =>
      settings.gitlabBaseUrl.trim().isNotEmpty &&
      settings.gitlabToken.trim().isNotEmpty &&
      settings.gitlabProjectIds.trim().isNotEmpty;

  bool get isGitlabConfigured => settings.noGitlabAccount || (_gitlabFieldsFilled && _gitlabAuthOk);

  bool get isAllConfigured => isJiraConfigured && isTimetacConfigured && isGitlabConfigured;

  // ---------- CSV → Arbeitsfenster ----------
  static bool _isCsvAbsence(String desc) {
    final d = desc.toLowerCase();
    return d.contains('urlaub') || d.contains('feiertag') || d.contains('krank') || d.contains('abwesen');
  }

  static bool _isCsvNonProductive(String desc) {
    final d = desc.toLowerCase();
    return d.contains('pause') || d.contains('arzt') || d.contains('nichtleistung') || d.contains('nicht-leistung');
  }

  static bool _isDefaultHomeofficeBlock(TimetacRow r) {
    if (!r.description.toLowerCase().contains('homeoffice')) return false;
    if (r.start == null || r.end == null) return false;
    final mins = r.end!.difference(r.start!).inMinutes;
    return mins >= 420 && mins <= 540;
  }

  // Arbeitsfenster inkl. Pausen-Abzug
  List<WorkWindow> workWindowsForDay(DateTime d) {
    final rows = timetac.where((r) => r.date.year == d.year && r.date.month == d.month && r.date.day == d.day);
    final raw = <WorkWindow>[];
    for (final r in rows) {
      if (_isCsvAbsence(r.description)) continue;
      if (_isCsvNonProductive(r.description)) continue;
      if (_isDefaultHomeofficeBlock(r)) continue;
      if (r.start != null && r.end != null) raw.add(WorkWindow(r.start!, r.end!));
    }
    if (raw.isEmpty) return raw;

    final pauses = <WorkWindow>[];
    for (final r in rows) {
      for (final pr in r.pauses) {
        pauses.add(WorkWindow(pr.start, pr.end));
      }
    }
    if (pauses.isEmpty) return raw;

    final cut = <WorkWindow>[];
    for (final w in raw) {
      cut.addAll(subtractIntervals(w, pauses));
    }
    return cut;
  }

  Duration _timetacProductiveOn(DateTime d) {
    final ws = workWindowsForDay(d);
    var total = Duration.zero;
    for (final w in ws) {
      total += w.duration;
    }
    return total;
  }

  Duration _meetingsIntersectedWithTimetac(DateTime d) {
    final workWindows = workWindowsForDay(d);
    if (workWindows.isEmpty) return Duration.zero;

    List<IcsEvent> meetings;
    if (userRangeCacheCoversDay(day: d, userEmail: settings.jiraEmail)) {
      meetings = meetingsForUserOnDayFast(day: d, userEmail: settings.jiraEmail);
    } else {
      meetings = buildDayCalendarCached(allEvents: icsEvents, day: d).meetings;
    }

    var sum = Duration.zero;
    for (final m in meetings) {
      for (final w in workWindows) {
        final s = m.start.isAfter(w.start) ? m.start : w.start;
        final e = m.end.isBefore(w.end) ? m.end : w.end;
        if (e.isAfter(s)) sum += e.difference(s);
      }
    }
    return sum;
  }

  List<DayTotals> get totals {
    final dates = <DateTime>{
      ...timetac.map((e) => DateTime(e.date.year, e.date.month, e.date.day)),
      ...icsEvents.map((e) => DateTime(e.start.year, e.start.month, e.start.day)),
    }.toList()
      ..sort();

    final selection = effectiveSelectedDates;
    if (selection.isNotEmpty) {
      dates.retainWhere((d) => selection.contains(DateTime(d.year, d.month, d.day)));
    }

    final out = <DayTotals>[];
    for (final d in dates) {
      final tt = _timetacProductiveOn(d);
      final mt = _meetingsIntersectedWithTimetac(d);

      // Tagessummen aus CSV
      final rows = timetac.where((r) => r.date.year == d.year && r.date.month == d.month && r.date.day == d.day);

      final ktDays = rows.fold<double>(0.0, (p, r) => p + r.sickDays);
      final ftDays = rows.fold<double>(0.0, (p, r) => p + r.holidayDays);
      final utHours = rows.fold<Duration>(Duration.zero, (p, r) => p + r.vacationHours);
      final zaHours = rows.fold<Duration>(Duration.zero, (p, r) => p + r.timeCompensationHours);

      // Arzttermin, nur wenn KT/FT/UT == 0
      final bnaSum = rows.fold<Duration>(Duration.zero, (p, r) => p + r.absenceTotal);
      final doctor = (ktDays == 0.0 && ftDays == 0.0 && utHours == Duration.zero && zaHours == Duration.zero)
          ? bnaSum
          : Duration.zero;

      out.add(DayTotals(
        date: d,
        timetacTotal: tt,
        meetingsTotal: mt,
        leftover: tt - mt - doctor,
        sickDays: ktDays,
        holidayDays: ftDays,
        vacationHours: utHours,
        doctorHours: doctor,
        timeCompensationHours: zaHours,
      ));
    }
    return out;
  }

  bool _intervalsOverlap(
    DateTime aStart,
    DateTime aEnd,
    DateTime bStart,
    DateTime bEnd,
  ) {
    final latestStart = aStart.isAfter(bStart) ? aStart : bStart;
    final earliestEnd = aEnd.isBefore(bEnd) ? aEnd : bEnd;
    return earliestEnd.isAfter(latestStart);
  }

  void _applyDeltaToDrafts(
    List<DraftLog> drafts,
    List<JiraWorklog> worklogs,
  ) {
    for (final d in drafts) {
      var state = DeltaState.newEntry;

      final sameIssueLogs = worklogs.where((w) => w.issueKey == d.issueKey).toList();

      for (final w in sameIssueLogs) {
        if (!_intervalsOverlap(d.start, d.end, w.started, w.end)) {
          continue;
        }

        final durationDiff = (d.duration.inSeconds - w.timeSpent.inSeconds).abs();
        final startDiffMinutes = d.start.difference(w.started).inMinutes.abs();

        final isDurationClose = durationDiff <= 60; // ±1 min
        final isStartClose = startDiffMinutes <= 5; // ±5 min

        if (isDurationClose && isStartClose) {
          state = DeltaState.duplicate;
          break; // exakter Treffer reicht
        } else {
          // zumindest Überlappung
          state = DeltaState.overlap;
        }
      }

      d.deltaState = state;
    }
  }

  Future<void> applyDeltaModeToDrafts(List<DraftLog> drafts) async {
    // Wenn keine Drafts: alles zurücksetzen und gut
    if (drafts.isEmpty) {
      _existingWorklogs = [];
      notifyListeners();
      return;
    }

    // Wenn Delta-Mode aus oder Jira nicht sauber → alle als "neu" markieren
    if (!deltaModeEnabled || !isJiraConfigured || jiraAccountId == null) {
      _existingWorklogs = [];
      _applyDeltaToDrafts(drafts, _existingWorklogs);
      notifyListeners();
      return;
    }

    // WIRKLICHER ZEITRAUM = Span deiner Drafts
    final minStart = drafts.map((d) => d.start).reduce((a, b) => a.isBefore(b) ? a : b);
    final maxEnd = drafts.map((d) => d.end).reduce((a, b) => a.isAfter(b) ? a : b);

    final api = JiraWorklogApi(
      baseUrl: settings.jiraBaseUrl,
      email: settings.jiraEmail,
      apiToken: settings.jiraApiToken,
    );

    final keys = drafts.map((d) => d.issueKey).toSet().toList();
    final all = <JiraWorklog>[];

    for (final key in keys) {
      try {
        final wls = await api.fetchWorklogsForIssue(issueKeyOrId: key);

        // Nur Worklogs von dir, die in den Draft-Zeitraum fallen
        final filtered = wls.where((w) {
          if (w.authorAccountId != jiraAccountId) return false;

          return _intervalsOverlap(
            w.started,
            w.end,
            minStart,
            maxEnd,
          );
        });

        all.addAll(filtered);
      } catch (_) {
        // Fehler bei einem Issue ignorieren – Delta-Modus lieber "zu defensiv"
      }
    }

    _existingWorklogs = all;
    _applyDeltaToDrafts(drafts, all);
    notifyListeners();
  }

  /// Gibt für einen Meeting-Titel das passende Jira-Ticket zurück.
  String resolveMeetingIssueKeyForTitle(String title) {
    // 1. Check if title starts with a ticket
    // Patterns: "PROJ-123: ...", "[PROJ-123] ...", "PROJ-123 ..."
    final reStart = RegExp(r'^\[?([A-Za-z][A-Za-z0-9]+-\d+)\]?[:\s]?', caseSensitive: false);
    final m = reStart.firstMatch(title.trim());
    if (m != null) {
      return m.group(1)!.toUpperCase();
    }

    final rules = settings.meetingRules;
    if (rules.isEmpty) return settings.meetingIssueKey;

    final lowerTitle = title.toLowerCase();

    for (final rule in rules) {
      final pattern = rule.pattern.trim();
      if (pattern.isEmpty) continue;

      if (lowerTitle.contains(pattern.toLowerCase())) {
        final ticket = rule.issueKey.trim();
        return ticket.isEmpty ? settings.meetingIssueKey : ticket;
      }
    }

    return settings.meetingIssueKey;
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _CT {
  _CT(this.at, this.ticket, this.projectId, this.msgFirstLine);
  DateTime at;
  String ticket;
  String projectId;
  String msgFirstLine;
}

class _HomePageState extends State<HomePage> {
  bool _busy = false;
  String _log = '';
  List<DraftLog> _drafts = [];
  List<DraftLog> _originalDrafts = []; // Backup for reset
  Map<String, String> _jiraSummaryCache = {};
  int _tabIndex = 1;

  bool _shownGitlabWarning = false;
  final Map<String, String> _issueOverrides = {}; // draftKey -> newKey
  String _draftKey(DraftLog d) => '${d.start.millisecondsSinceEpoch}-${d.end.millisecondsSinceEpoch}-${d.issueKey}';

  // Update Service
  final UpdateService _updateService = UpdateService();

  @override
  void initState() {
    super.initState();
    // Check for updates on app start
    _updateService.checkForUpdates().then((info) {
      if (mounted) {
        setState(() {});
        if (info != null && info.updateAvailable) {
          _showUpdateDialog(context);
        }
      }
    });
    _updateService.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _updateService.dispose();
    super.dispose();
  }

  String? _leadingTicket(String msg) {
    if (msg.isEmpty) return null;
    if (msg.toLowerCase().startsWith('merge')) return null;
    final line = msg.split('\n').first.trimLeft();
    final cleaned = line.replaceFirst(RegExp(r'^[^\w\[]+'), '');
    final reStart = RegExp(r'^\[?([A-Za-z][A-Za-z0-9]+-\d+)\]?:?', caseSensitive: false);
    final m = reStart.firstMatch(cleaned);
    if (m != null) return m.group(1)!.toUpperCase();
    final m2 = RegExp(r'([A-Za-z][A-Za-z0-9]+-\d+)', caseSensitive: false).firstMatch(line);
    return m2?.group(1)?.toUpperCase();
  }

  String _firstLine(String s) => s.split('\n').first.trim();

  Set<String> _emailsFromSettings(SettingsModel s) {
    final raw = (s.gitlabAuthorEmail.trim().isEmpty ? s.jiraEmail : s.gitlabAuthorEmail).trim();
    final parts = raw.split(RegExp(r'[,\s]+')).map((e) => e.trim().toLowerCase()).where((e) => e.contains('@')).toSet();
    return parts;
  }

  List<GitlabCommit> _filterCommitsByEmails(List<GitlabCommit> commits, Set<String> emails) {
    if (emails.isEmpty) return commits;
    return commits.where((c) {
      final a = c.authorEmail?.toLowerCase();
      final ce = c.committerEmail?.toLowerCase();
      return (a != null && emails.contains(a)) || (ce != null && emails.contains(ce));
    }).toList();
  }

  List<_CT> _sortedCommitsWithTickets(List<GitlabCommit> commits) {
    final out = <_CT>[];
    for (final c in commits) {
      final t = _leadingTicket(c.message);
      if (t == null) continue;
      out.add(_CT(c.createdAt, t, c.projectId, _firstLine(c.message)));
    }
    out.sort((a, b) => a.at.compareTo(b.at));
    return out;
  }

  void _logCommitsForDay(DateTime day, List<_CT> ordered, void Function(String) log) {
    final ds = DateTime(day.year, day.month, day.day);
    final de = ds.add(const Duration(days: 1));
    final list = ordered.where((c) => !c.at.isBefore(ds) && c.at.isBefore(de)).toList();
    if (list.isEmpty) {
      log('  Commits: —\n');
      return;
    }
    log('  Commits:\n');
    for (final c in list) {
      log('    ${DateFormat('HH:mm').format(c.at)}  [${c.ticket}]  (Proj ${c.projectId})  ${c.msgFirstLine}\n');
    }
  }

  String? _lastTicketBefore(List<_CT> ordered, DateTime t) {
    int lo = 0, hi = ordered.length - 1, idx = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (ordered[mid].at.isAfter(t)) {
        hi = mid - 1;
      } else {
        idx = mid;
        lo = mid + 1;
      }
    }
    return idx >= 0 ? ordered[idx].ticket : null;
  }

  // Hilfsfunktion: kürzt eine Liste Arbeits-Intervalle (chronologisch) um N Minuten von hinten
  List<WorkWindow> _trimPiecesFromEndBy(Duration cut, List<WorkWindow> pieces) {
    if (cut <= Duration.zero || pieces.isEmpty) return pieces;
    final res = <WorkWindow>[];
    int totalCut = cut.inSeconds;

    // von hinten nach vorn
    for (int i = pieces.length - 1; i >= 0; i--) {
      final w = pieces[i];
      final len = w.duration.inSeconds;
      if (totalCut <= 0) {
        res.add(w);
        continue;
      }
      if (totalCut >= len) {
        totalCut -= len; // komplettes Fenster fällt weg
        continue;
      } else {
        // kürze das letzte Fenster am Ende
        res.add(WorkWindow(w.start, w.end.subtract(Duration(seconds: totalCut))));
        totalCut = 0;
      }
    }
    res.sort((a, b) => a.start.compareTo(b.start));
    return res;
  }

  /// Resolve Overlaps by "Punch Hole": Later (or more specific) meetings overwrite earlier ones.
  List<DraftLog> _resolveMeetingOverlaps(List<DraftLog> inputs) {
    if (inputs.isEmpty) return [];

    // 1. Sort: Start ASC, then Duration DESC (Longer first -> processed earlier -> overwritten by shorter)
    final sorted = inputs.toList()..sort((a, b) {
      final cmp = a.start.compareTo(b.start);
      if (cmp != 0) return cmp;
      return b.duration.compareTo(a.duration); // Descending duration
    });

    final result = <DraftLog>[];

    for (final candidate in sorted) {
      final newResult = <DraftLog>[];
      
      for (final existing in result) {
         final parts = _subtractDraft(existing, candidate);
         newResult.addAll(parts);
      }
      
      newResult.add(candidate);
      result.clear();
      result.addAll(newResult);
    }
    
    result.sort((a, b) => a.start.compareTo(b.start));
    return result;
  }
  
  List<DraftLog> _subtractDraft(DraftLog source, DraftLog hole) {
     final overlapStart = source.start.isAfter(hole.start) ? source.start : hole.start;
     final overlapEnd = source.end.isBefore(hole.end) ? source.end : hole.end;
     
     if (overlapEnd.isAfter(overlapStart)) {
        final parts = <DraftLog>[];
        if (source.start.isBefore(overlapStart)) {
           parts.add(source.copy()..end = overlapStart);
        }
        if (source.end.isAfter(overlapEnd)) {
           parts.add(source.copy()..start = overlapEnd);
        }
        return parts;
     }
     return [source];
  }

  List<DraftLog> _assignRestPiecesByCommits({
    required List<WorkWindow> pieces,
    required List<_CT> ordered,
    required String note,
    required void Function(String) log,
  }) {
    final drafts = <DraftLog>[];

    for (final piece in pieces) {
      DateTime segStart = piece.start;
      final segEndTotal = piece.end;

      String? currentTicket = _lastTicketBefore(ordered, piece.start);
      if (currentTicket == null) {
        final next = ordered.firstWhere(
          (c) => !c.at.isBefore(piece.start),
          orElse: () => _CT(DateTime.fromMillisecondsSinceEpoch(0), '', '', ''),
        );
        if (next.ticket.isNotEmpty) {
          currentTicket = next.ticket;
          if (next.at.isAfter(segStart) && next.at.isBefore(segEndTotal)) {
            log('    ↳ Forward-Fill bis ${DateFormat('HH:mm').format(next.at)} mit [$currentTicket]\n');
          }
        }
      }

      if (currentTicket == null) {
        log('    ⚠ Keine passenden Commits – Arbeit ${DateFormat('HH:mm').format(piece.start)}–${DateFormat('HH:mm').format(piece.end)} wird ausgelassen\n');
        continue;
      }

      final inside = ordered.where((c) => c.at.isAfter(piece.start) && c.at.isBefore(piece.end)).toList();

      for (final c in inside) {
        if (c.ticket != currentTicket) {
          if (c.at.isAfter(segStart)) {
            drafts.add(DraftLog(start: segStart, end: c.at, issueKey: currentTicket!, note: note));
            log('    Arbeit ${DateFormat('HH:mm').format(segStart)}–${DateFormat('HH:mm').format(c.at)} → [$currentTicket] (Commit ${DateFormat('HH:mm').format(c.at)})\n');
          }
          currentTicket = c.ticket;
          segStart = c.at;
        }
      }

      if (segEndTotal.isAfter(segStart)) {
        drafts.add(DraftLog(start: segStart, end: segEndTotal, issueKey: currentTicket!, note: note));
        log('    Arbeit ${DateFormat('HH:mm').format(segStart)}–${DateFormat('HH:mm').format(segEndTotal)} → [$currentTicket]\n');
      }
    }

    return drafts;
  }

  // ---------- UI ----------

  Widget _switchedSection(BuildContext context) {
    final state = context.watch<AppState>();

    // Index 0 is Tools, so shift others by 1
    if (_tabIndex == 1) {
      // Preview
      if (state.totals.isEmpty) {
        return const Padding(
          padding: EdgeInsets.all(12.0),
          child: Text('Keine Daten für die Vorschau.'),
        );
      }
      return PreviewTable(days: state.totals);
    }

    if (_tabIndex == 2) {
      // Geplante Worklogs
      if (_drafts.isEmpty) {
        return const Padding(
          padding: EdgeInsets.all(12.0),
          child: Text('Noch keine geplanten Worklogs.'),
        );
      }
      return _plannedList(context, _drafts);
    }

    // Logs (_tabIndex == 3)
    if (_log.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12.0),
        child: Text('Noch keine Logs.'),
      );
    }
    return _buildLogBox();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final locked = !state.isAllConfigured;

    if (state.settings.noGitlabAccount && !_shownGitlabWarning) {
      // Post-Frame callback to show dialog
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _shownGitlabWarning = true);
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(children: [
              Icon(Icons.warning_amber_rounded, color: Colors.orange),
              SizedBox(width: 8),
              Text('Kein GitLab Account'),
            ]),
            content: const Text(
              'Du hast angegeben, keinen GitLab Account zu haben.\n\n'
              'Die automatische Zuordnung von Jira-Tickets basierend auf deinen Commits '
              'ist daher deaktiviert. Du musst die Tickets manuell zuordnen.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Verstanden'),
              ),
            ],
          ),
        );
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Chronos'),
            const SizedBox(width: 12),
            Text(
              'v${_updateService.currentVersion}',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(width: 12),
            _buildUpdateWidget(),
          ],
        ),
        actionsPadding: const EdgeInsets.only(right: 12.0),
        actions: [
          _statusPill(state.isJiraConfigured, 'Jira'),
          _statusPill(state.isTimetacConfigured, 'Timetac'),
          _statusPill(state.isGitlabConfigured, 'GitLab',
              warn: state.settings.noGitlabAccount),
          const SizedBox(width: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(state.isDark ? Icons.light_mode : Icons.dark_mode),
                  onPressed: () => context.read<AppState>().toggleTheme(),
                ),
                const SizedBox(width: 6),
                Text(
                  state.isDark ? 'Dunkles Theme aktiv' : 'Helles Theme aktiv',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 24),
          IconButton(icon: const Icon(Icons.settings), onPressed: () => _openSettings(context)),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _tabIndex,
        onTap: (i) => setState(() => _tabIndex = i),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.delete_sweep),
            label: 'Löschen',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.table_chart),
            label: 'Vorschau',
          ),
          BottomNavigationBarItem(icon: Icon(Icons.view_list), label: 'Geplant'),
          BottomNavigationBarItem(
            icon: Icon(Icons.receipt_long),
            label: 'Logs',
          ),
        ],
      ),
      body: Stack(
        children: [
          AbsorbPointer(
            absorbing: locked || _busy,
            child: _tabIndex == 0
                ? const DeleteModeScreen()
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 12,
                      children: [
                        _buildImportButtons(context),
                        _buildRangePicker(context),
                        _buildCalculateButtons(context),
                        _switchedSection(context),
                      ],
                    ),
                  ),
          ),
          if (locked) _lockOverlay(context, state),
          if (_busy) _busyOverlay(context),
        ],
      ),
    );
  }

  // Update-Widget für die AppBar
  Widget _buildUpdateWidget() {
    if (_updateService.isChecking) {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    final info = _updateService.updateInfo;
    if (info == null) {
      return const SizedBox.shrink();
    }

    if (!info.updateAvailable) {
      return Tooltip(
        message: 'Aktuelle Version',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_circle,
              size: 16,
              color: Colors.green.shade400,
            ),
            const SizedBox(width: 4),
            Text(
              'Aktuell',
              style: TextStyle(
                fontSize: 11,
                color: Colors.green.shade400,
              ),
            ),
          ],
        ),
      );
    }

    // Update available
    return FilledButton.tonal(
      onPressed: () => _showUpdateDialog(context),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.download, size: 14),
          const SizedBox(width: 4),
          Text(
            'Update auf v${info.latestVersion}',
            style: const TextStyle(fontSize: 11),
          ),
        ],
      ),
    );
  }

  Future<void> _showUpdateDialog(BuildContext ctx) async {
    final info = _updateService.updateInfo;
    if (info == null || !info.updateAvailable) return;

    final confirmed = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: const Text('Update verfügbar'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Neue Version: v${info.latestVersion}'),
            Text('Aktuelle Version: v${info.currentVersion}'),
            const SizedBox(height: 16),
            if (info.releaseNotes.isNotEmpty) ...[
              const Text('Release Notes:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 200, maxWidth: 400),
                child: Scrollbar(
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    child: MarkdownBody(
                      data: info.releaseNotes,
                      styleSheet: MarkdownStyleSheet(
                        p: const TextStyle(fontSize: 13),
                        h1: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        h2: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        h3: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                        listBullet: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('Später'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('Jetzt updaten'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    // Show progress dialog
    showDialog(
      context: ctx,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: const Text('Lade Update herunter...'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            AnimatedBuilder(
              animation: _updateService,
              builder: (context, _) => Column(
                children: [
                  LinearProgressIndicator(value: _updateService.downloadProgress),
                  const SizedBox(height: 8),
                  Text('${(_updateService.downloadProgress * 100).toStringAsFixed(0)}%'),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    // Start download and wait for completion
    final scriptPath = await _updateService.downloadAndExtract();
    
    // Close progress dialog
    if (mounted) Navigator.of(ctx).pop();

    if (!mounted) return;

    if (scriptPath != null) {
      // Show restart dialog
      final restart = await showDialog<bool>(
        context: ctx,
        barrierDismissible: false,
        builder: (c) => AlertDialog(
          icon: const Icon(Icons.check_circle, color: Colors.green, size: 48),
          title: const Text('Update bereit'),
          content: const Text(
            'Das Update wurde heruntergeladen und entpackt.\n\n'
            'Die Anwendung wird jetzt neu gestartet, um das Update zu installieren.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(c).pop(true),
              child: const Text('Jetzt neustarten'),
            ),
          ],
        ),
      );

      if (restart == true) {
        await _updateService.executeUpdate(scriptPath);
        exit(0);
      }
    } else if (_updateService.error != null) {
      // Show error dialog
      await showDialog(
        context: ctx,
        builder: (c) => AlertDialog(
          icon: const Icon(Icons.error, color: Colors.red, size: 48),
          title: const Text('Update fehlgeschlagen'),
          content: Text(_updateService.error ?? 'Unbekannter Fehler'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(c).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  // kleine Statusanzeige (Icon + Label darunter)
  Widget _statusPill(bool ok, String label, {bool warn = false}) {
    final color = warn ? Colors.orange : (ok ? Colors.green : Colors.red);
    final icon = warn ? Icons.warning_amber_rounded : (ok ? Icons.check_circle : Icons.cancel);

    return Semantics(
      label: '$label ${ok ? "konfiguriert" : "fehlt"}',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  Widget _deltaBadge(DraftLog d) {
    IconData icon;
    Color color;
    String tooltip;

    switch (d.deltaState) {
      case DeltaState.newEntry:
        icon = Icons.fiber_new;
        color = Colors.green;
        tooltip = 'Neu – noch nicht in Jira vorhanden';
        break;
      case DeltaState.duplicate:
        icon = Icons.check_circle;
        color = Colors.grey;
        tooltip = 'Duplikat – sehr ähnlich zu bestehendem Jira-Worklog';
        break;
      case DeltaState.overlap:
        icon = Icons.warning_amber_rounded;
        color = Colors.orange;
        tooltip = 'Überlappung – schneidet bestehenden Jira-Worklog';
        break;
    }

    return Tooltip(
      message: tooltip,
      child: Icon(
        icon,
        size: 18,
        color: color,
      ),
    );
  }

  Widget _deltaLegend() {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.fiber_new, size: 16, color: Colors.green),
                SizedBox(width: 4),
                Text('Neu', style: TextStyle(fontSize: 12)),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle, size: 16, color: Colors.grey),
                SizedBox(width: 4),
                Text('Duplikat', style: TextStyle(fontSize: 12)),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange),
                SizedBox(width: 4),
                Text('Überlappend', style: TextStyle(fontSize: 12)),
              ],
            ),
          ],
        ),
        Text(
          '(Überlappende/Duplizierte Buchungen werden beim Buchen übersprungen)',
          style: TextStyle(
            fontStyle: FontStyle.italic,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  // Overlay wenn gesperrt
  Widget _lockOverlay(BuildContext context, AppState state) {
    final missing = <String>[];
    if (!state.isJiraConfigured) missing.add('Jira');
    if (!state.isTimetacConfigured) missing.add('Timetac (CSV-Felder)');
    if (!state.isGitlabConfigured) missing.add('GitLab');

    return Container(
      color: Colors.black54,
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Card(
          elevation: 8,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('🔒', style: TextStyle(fontSize: 48)),
              const SizedBox(height: 8),
              Text('App gesperrt – fehlende Einstellungen', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                'Bitte vervollständige die folgenden Bereiche in den Einstellungen:\n• ${missing.join('\n• ')}',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => _openSettings(context),
                icon: const Icon(Icons.settings),
                label: const Text('Einstellungen öffnen'),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  // Overlay beim Berechnen/Senden
  Widget _busyOverlay(BuildContext context) {
    return Container(
      color: Colors.black38,
      alignment: Alignment.center,
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: const Padding(
          padding: EdgeInsets.all(20),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(width: 8),
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('Bitte warten…'),
            SizedBox(width: 8),
          ]),
        ),
      ),
    );
  }

  void _splitLog(DraftLog log) {
    final duration = log.duration;
    if (duration.inMinutes < 2) return;

    final half = Duration(minutes: (duration.inMinutes / 2).round());
    final mid = log.start.add(half);

    final part1 = DraftLog(
      start: log.start,
      end: mid,
      issueKey: log.issueKey,
      note: log.note,
      deltaState: log.deltaState,
      isManuallyModified: true,
    );
    final part2 = DraftLog(
      start: mid,
      end: log.end,
      issueKey: log.issueKey,
      note: log.note,
      deltaState: log.deltaState,
      isManuallyModified: true,
    );

    setState(() {
      final idx = _drafts.indexOf(log);
      if (idx != -1) {
        _drafts.removeAt(idx);
        _drafts.insert(idx, part2);
        _drafts.insert(idx, part1);
      }
    });
  }

  void _mergeLog(DraftLog log, bool up) {
    setState(() {
      final idx = _drafts.indexOf(log);
      if (idx == -1) return;

      if (up) {
        if (idx > 0) {
          final prev = _drafts[idx - 1];
          // Prevent cross-day merge
          if (prev.start.day != log.start.day || prev.start.month != log.start.month || prev.start.year != log.start.year) {
             return;
          }

          prev.end = log.end;
          if (prev.note != log.note) {
            prev.note = '${prev.note} | ${log.note}';
          }
          prev.isManuallyModified = true;
          _drafts.removeAt(idx);
        }
      } else {
        if (idx < _drafts.length - 1) {
          final next = _drafts[idx + 1];
          // Prevent cross-day merge
          if (next.start.day != log.start.day || next.start.month != log.start.month || next.start.year != log.start.year) {
             return;
          }

          log.end = next.end;
          if (log.note != next.note) {
            log.note = '${log.note} | ${next.note}';
          }
          log.isManuallyModified = true;
          _drafts.removeAt(idx + 1);
        }
      }
    });
  }

  void _updateLogTime(DraftLog log, DateTime newStart, DateTime newEnd) {
    setState(() {
      final idx = _drafts.indexOf(log);
      if (idx == -1) return;

      final oldStart = log.start;
      final oldEnd = log.end;

      log.start = newStart;
      log.end = newEnd;
      log.isManuallyModified = true;

      // Smart Adjustment
      if (idx > 0) {
        final prev = _drafts[idx - 1];
        if (_isSameDay(prev.start, log.start) && prev.end.isAtSameMomentAs(oldStart)) {
          // If previous ended exactly when this one started, update previous end
          if (newStart.isAfter(prev.start)) {
             prev.end = newStart;
             prev.isManuallyModified = true;
          }
        }
      }

      if (idx < _drafts.length - 1) {
        final next = _drafts[idx + 1];
        if (_isSameDay(next.start, log.start) && next.start.isAtSameMomentAs(oldEnd)) {
          // If next started exactly when this one ended, update next start
          if (newEnd.isBefore(next.end)) {
            next.start = newEnd;
            next.isManuallyModified = true;
          }
        }
      }
      
      // Re-sort just in case, though usually not needed if small adjustments
      _drafts.sort((a, b) => a.start.compareTo(b.start));
    });
  }

  void _deleteLog(DraftLog log) {
    setState(() {
      final idx = _drafts.indexOf(log);
      if (idx != -1) {
        // Smart Delete: Extend previous log if contiguous
        if (idx > 0) {
          final prev = _drafts[idx - 1];
          if (_isSameDay(prev.start, log.start) && prev.end.isAtSameMomentAs(log.start)) {
             prev.end = log.end;
             prev.isManuallyModified = true;
             
             // Check if we now overlap with next (shouldn't happen if log was valid, but good to be safe)
             if (idx < _drafts.length - 1) {
               final next = _drafts[idx + 1];
               if (_isSameDay(prev.start, next.start) && prev.end.isAfter(next.start)) {
                 prev.end = next.start;
               }
             }
          }
        }
        _drafts.removeAt(idx);
      }
    });
  }

  void _insertLog(int indexAfter, DateTime start, {bool isPause = false, bool isDoctorAppointment = false}) {
    setState(() {
      // Default duration 5 mins (15 for pause, 60 for doctor appointment)
      var end = start.add(Duration(minutes: isPause ? 15 : (isDoctorAppointment ? 60 : 5)));
      
      // Smart Insert: Shift next log if overlap
      if (indexAfter < _drafts.length) {
        final next = _drafts[indexAfter];
        if (_isSameDay(next.start, start)) {
           // If new log ends after next starts, push next start
           if (end.isAfter(next.start)) {
             next.start = end;
             // If that makes next duration negative/zero, push end too? 
             // Let's just ensure min 1 min for next
             if (next.end.difference(next.start).inMinutes < 1) {
               next.end = next.start.add(const Duration(minutes: 1));
             }
           }
        }
      }
      
      final newLog = DraftLog(
        start: start,
        end: end,
        issueKey: (isPause || isDoctorAppointment) ? '' : context.read<AppState>().settings.fallbackIssueKey,
        note: isPause ? 'Pause' : (isDoctorAppointment ? 'Bezahlte Nichtarbeitszeit' : ''),
        deltaState: DeltaState.newEntry,
        isManuallyModified: true,
        isPause: isPause,
        isDoctorAppointment: isDoctorAppointment,
      );
      
      _drafts.insert(indexAfter, newLog);
    });
  }

  void _resetDay(String dayKey) {
    // dayKey format: dd.MM.yyyy
    setState(() {
      // 1. Remove current drafts for this day
      _drafts.removeWhere((d) => DateFormat('dd.MM.yyyy').format(d.start) == dayKey);
      
      // 2. Find original drafts for this day
      final originalForDay = _originalDrafts.where((d) => DateFormat('dd.MM.yyyy').format(d.start) == dayKey);
      
      // 3. Add copies of original drafts
      _drafts.addAll(originalForDay.map((d) => d.copy()));
      
      // 4. Sort
      _drafts.sort((a, b) => a.start.compareTo(b.start));
    });
  }

  void _resetAll() {
    setState(() {
      _drafts = _originalDrafts.map((d) => d.copy()).toList();
    });
  }

  Widget _plannedList(BuildContext context, List<DraftLog> drafts) {
    final settings = context.read<AppState>().settings;
    final jira = JiraApi(baseUrl: settings.jiraBaseUrl, email: settings.jiraEmail, apiToken: settings.jiraApiToken);
    final byDay = <String, List<DraftLog>>{};
    for (final d in drafts) {
      final key = DateFormat('dd.MM.yyyy').format(d.start);
      (byDay[key] ??= []).add(d);
    }
    final dayKeys = byDay.keys.toList()
      ..sort((a, b) {
        final dateA = DateFormat('dd.MM.yyyy').parse(a);
        final dateB = DateFormat('dd.MM.yyyy').parse(b);
        return dateA.compareTo(dateB);
      });

    final meetingKey = context.read<AppState>().settings.meetingIssueKey;

    // Berechne maximale Ticket-Breite basierend auf der längsten Ticket-Nummer
    final maxTicketLength = drafts.fold<int>(0, (max, d) => d.issueKey.length > max ? d.issueKey.length : max);
    // Monospace-Schrift: ca. 8.5px pro Zeichen + etwas Puffer
    final ticketWidth = (maxTicketLength * 8.5 + 12).clamp(80.0, 200.0);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Geplante Worklogs', style: Theme.of(context).textTheme.titleMedium),
              TextButton.icon(
                onPressed: _resetAll,
                icon: const Icon(Icons.restore, size: 16),
                label: const Text('Alle Zeitänderungen zurücksetzen'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _deltaLegend(),
          const SizedBox(height: 16),
          for (final day in dayKeys) ...[
            Builder(builder: (context) {
              final dayLogs = byDay[day]!;
              // Gesamtdauer: Pausen ausschließen, bezahlte Nichtarbeitszeit einschließen
              final totalDuration = dayLogs
                .where((log) => !log.isPause)  // Pausen nicht mitzählen
                .fold<Duration>(
                  Duration.zero,
                  (sum, log) => sum + log.duration,
                );
              final hours = totalDuration.inHours;
              final minutes = totalDuration.inMinutes.remainder(60);
              final totalStr = '${hours}h ${minutes.toString().padLeft(2, '0')}m';
              
              return Row(
                children: [
                  Text(day, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(width: 8),
                  Text(
                    '($totalStr)',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () => _resetDay(day),
                    icon: const Icon(Icons.restore, size: 16),
                    label: const Text('Zeitänderungen zurücksetzen'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                ],
              );
            }),
            const SizedBox(height: 8),
            for (final w in byDay[day]!)
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 2),
                child: Builder(builder: (_) {
                  final draftId = _draftKey(w);
                  final effectiveKey = _issueOverrides[draftId] ?? w.issueKey;
                  
                  // Override key in draft temporarily for display if needed, 
                  // but DraftLogTile uses draft.issueKey. 
                  // Actually we should sync them.
                  if (effectiveKey != w.issueKey) {
                     w.issueKey = effectiveKey;
                  }

                  final idx = _drafts.indexOf(w);
                  // Check bounds and same day for merge
                  final canUp = idx > 0 && _isSameDay(_drafts[idx - 1].start, w.start);
                  final canDown = idx < _drafts.length - 1 && _isSameDay(_drafts[idx + 1].start, w.start);

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Insert Divider BEFORE first log of day
                      if (w == byDay[day]!.first)
                        _HoverableInsertDivider(
                          onInsertWorklog: () {
                             // Insert before this log
                             // Start = w.start - 5min
                             final start = w.start.subtract(const Duration(minutes: 5));
                             _insertLog(idx, start);
                          },
                          onInsertPause: () {
                             final start = w.start.subtract(const Duration(minutes: 15));
                             _insertLog(idx, start, isPause: true);
                          },
                          onInsertDoctorAppointment: () {
                             final start = w.start.subtract(const Duration(minutes: 60));
                             _insertLog(idx, start, isDoctorAppointment: true);
                          },
                        ),

                      DraftLogTile(
                        key: ValueKey(w),
                        draft: w,
                        ticketWidth: ticketWidth,
                        canMergeUp: canUp,
                        canMergeDown: canDown,
                        onChanged: () => setState(() {}),
                        onSplit: () => _splitLog(w),
                        onMerge: (up) => _mergeLog(w, up),
                        onTimeChanged: (s, e) => _updateLogTime(w, s, e),
                        onDelete: () => _deleteLog(w),
                        onTicketChanged: (newKey) {
                          setState(() {
                            _issueOverrides[draftId] = newKey;
                            w.issueKey = newKey;
                            w.isManuallyModified = true;
                            if (!_jiraSummaryCache.containsKey(newKey)) {
                              jira.fetchSummariesByKeys({newKey}).then((m) {
                                if (m.isNotEmpty && mounted) {
                                  setState(() => _jiraSummaryCache.addAll(m));
                                }
                              });
                            }
                          });
                        },
                        onPickTicket: () => _openIssuePickerDialog(
                          originalKey: w.issueKey,
                          currentKey: effectiveKey,
                          title: 'Ticket für ${DateFormat('dd.MM.yyyy HH:mm').format(w.start)} ändern',
                        ),
                      ),
                      // Insert Divider
                      _HoverableInsertDivider(
                        onInsertWorklog: () {
                           // Insert after this log
                           // Default start is this log's end
                           _insertLog(idx + 1, w.end);
                        },
                        onInsertPause: () {
                           _insertLog(idx + 1, w.end, isPause: true);
                        },
                        onInsertDoctorAppointment: () {
                           _insertLog(idx + 1, w.end, isDoctorAppointment: true);
                        },
                      ),
                    ],
                  );
                }),
              ),
            const Divider(),
          ],
        ]),
      ),
    );
  }

  Widget _buildImportButtons(BuildContext context) {
    final state = context.watch<AppState>();
    String fmt(Duration d) => formatDuration(d);
    final ttSum = state.timetac.fold<Duration>(Duration.zero, (p, e) => p + e.duration);
    final evSum = state.totals.fold<Duration>(Duration.zero, (sum, day) => sum + day.meetingsTotal);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Datenquellen', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(children: [
            FilledButton.icon(
              onPressed: () async {
                setState(() => _busy = true);
                final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['csv']);
                if (res != null && res.files.single.path != null) {
                  setState(() => _busy = true);
                  try {
                    final bytes = await File(res.files.single.path!).readAsBytes();
                    if (!context.mounted) return;
                    final s = context.read<AppState>().settings;
                    final parsed = TimetacCsvParser.parseWithConfig(bytes, s);
                    setState(() {
                      context.read<AppState>().timetac = parsed;
                      _drafts = [];
                      _log = 'CSV geladen: ${parsed.length} Zeilen\n';
                      final days = parsed.map((r) => r.date).toSet().toList()..sort();
                      if (days.isNotEmpty) {
                        _log += 'CSV-Tage: ${days.first} … ${days.last} (${days.length} Tage)\n';
                      }
                    });
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text('CSV geladen: ${parsed.length} Zeilen')));
                  } catch (e) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('CSV-Import fehlgeschlagen')));
                    setState(() => _log += 'FEHLER CSV-Import: $e\n');
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                } else {
                  setState(() => _busy = false);
                }
              },
              icon: const Icon(Icons.table_chart),
              label: const Text('Timetac CSV laden'),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Info zu CSV-Import',
              icon: const Icon(Icons.info_outline),
              onPressed: () {
                _showInfoDialog(
                  'Timetac CSV-Datei bekommen - Anleitung',
                  'Schritt 1: Öffne Timetac.\n'
                      'Schritt 2: Wechsle zum Tab "Stundenabrechnung".\n'
                      'Schritt 3: Gebe in die Datumsfelder jeweils das Start- und Enddatum ein für den Zeitraum den du buchen willst (Am Besten gleich wie bei Outlook)\n'
                      'Schritt 4: Drücke auf den Aktualisieren-Button.\n'
                      'Schritt 5: Klicke rechts auf den Button "Exportieren als CSV-Datei".\n'
                      'Schritt 6: Klicke im geöffneten Dialog auf "Herunterladen".\n'
                      'Schritt 7: In dieser Anwendung die CSV-Datei importieren und kurz warten.\n',
                );
              },
            ),
            const SizedBox(width: 12),
            Text(ttSum == Duration.zero ? '—' : 'Summe Timetac: ${fmt(ttSum)}'),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            FilledButton.icon(
              onPressed: () async {
                setState(() => _busy = true);
                final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['ics']);
                if (res != null && res.files.single.path != null) {
                  try {
                    final content = await File(res.files.single.path!).readAsString();
                    if (!context.mounted) return;
                    final userMail = context.read<AppState>().settings.jiraEmail;
                    final parsed = parseIcs(content, selfEmail: userMail);
                    clearIcsDayCache();
                    clearIcsRangeCache();
                    setState(() {
                      context.read<AppState>().icsEvents = parsed.events;
                      _drafts = [];
                      _log += 'ICS geladen: ${parsed.events.length} Events\n';
                    });
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text('ICS geladen: ${parsed.events.length} Events')));
                  } catch (e) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('ICS-Import fehlgeschlagen')));
                    setState(() => _log += 'FEHLER ICS-Import: $e\n');
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                } else {
                  setState(() => _busy = false);
                }
              },
              icon: const Icon(Icons.event),
              label: const Text('Outlook .ics laden'),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Info zu ICS-Import',
              icon: const Icon(Icons.info_outline),
              onPressed: () {
                _showInfoDialog(
                  'Outlook ICS-Datei bekommen - Anleitung',
                  'Schritt 1: Outlook (Classic) öffnen (WICHTIG! Es muss wirklich Outlook Classic sein.)\n'
                      'Schritt 2: Links auf den Kalendar-Tab wechseln.\n'
                      'Schritt 3: Oben auf den Reiter "Datei" klicken.\n'
                      'Schritt 4: Links im Menü "Kalendar speichern" klicken.\n'
                      'Schritt 5: Im Explorer-Fenster unten auf "Weitere Optionen" klicken\n'
                      'Schritt 6: Bei Datumsbereich "Datum angeben..." auswählen und gewünschtes Beginn- und Enddatum für die Zeitbuchung wählen (Am Besten gleich wie bei Timetac).\n'
                      'Schritt 7: Bei Detail "Alle Details" auswählen.\n'
                      'Schritt 8: Bei Erweitert auf ">> Einblenden" klicken.\n'
                      'Schritt 9: "Details von als privat markierten Elementen einschließen" aktivieren.\n'
                      'Schritt 10: Auf "OK" klicken und die Datei irgendwo speichern, warten bis Outlook alles exportiert hat.\n'
                      'Schritt 11: In dieser Anwendung die ICS-Datei importieren und etwas länger warten (Keine Sorge, das ist normal, dass sich das Programm kurz aufhängt).\n',
                );
              },
            ),
            const SizedBox(width: 12),
            Text(evSum == Duration.zero ? '—' : 'Meetings (gemergt) gesamt: ${fmt(evSum)}'),
          ]),
        ]),
      ),
    );
  }

  Widget _buildRangePicker(BuildContext context) {
    final state = context.watch<AppState>();
    final activeRange = state.range;
    final dates = {
      ...state.timetac.map((e) => e.date),
      ...state.icsEvents.map((e) => DateTime(e.start.year, e.start.month, e.start.day)),
    }.toList()
      ..sort();
    final minDate = dates.isNotEmpty ? dates.first : DateTime.now();
    final maxDate = dates.isNotEmpty ? dates.last : DateTime.now();
    
    final isRangeMode = state.dateSelectionRangeMode;
    final selectedCount = state.selectedDates.length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Datumsbereich', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(children: [
            FilledButton.tonalIcon(
              onPressed: dates.isEmpty
                  ? null
                  : () => _showUnifiedDatePicker(context, minDate, maxDate),
              icon: Icon(isRangeMode ? Icons.date_range : Icons.check_box_outlined),
              label: Text(
                isRangeMode
                    ? (activeRange == null
                        ? 'Zeitraum wählen'
                        : '${DateFormat('dd.MM.yyyy').format(activeRange.start)} – '
                            '${DateFormat('dd.MM.yyyy').format(activeRange.end)}')
                    : (selectedCount == 0
                        ? 'Tage auswählen'
                        : '$selectedCount ${selectedCount == 1 ? 'Tag' : 'Tage'} ausgewählt'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
  
  /// Shows a unified scrollable calendar dialog for selecting dates (range or individual days)
  Future<void> _showUnifiedDatePicker(BuildContext ctx, DateTime minDate, DateTime maxDate) async {
    final state = context.read<AppState>();
    
    // Mutable mode variable (can be toggled in dialog)
    var isRangeMode = state.dateSelectionRangeMode;
    
    // For range mode: track start and end
    DateTime? rangeStart = state.range?.start;
    DateTime? rangeEnd = state.range?.end;
    
    // For individual mode: copy current selection
    final tempSelection = Set<DateTime>.from(state.selectedDates);
    
    // Available dates from CSV/ICS
    final availableDates = {
      ...state.timetac.map((e) => DateTime(e.date.year, e.date.month, e.date.day)),
      ...state.icsEvents.map((e) => DateTime(e.start.year, e.start.month, e.start.day)),
    };
    
    final confirmed = await showDialog<bool>(
      context: ctx,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) {
          // Helper to get selected dates for display
          Set<DateTime> getDisplayDates() {
            if (isRangeMode) {
              if (rangeStart != null && rangeEnd != null) {
                final dates = <DateTime>{};
                var d = rangeStart!;
                while (!d.isAfter(rangeEnd!)) {
                  dates.add(DateTime(d.year, d.month, d.day));
                  d = d.add(const Duration(days: 1));
                }
                return dates;
              } else if (rangeStart != null) {
                return {rangeStart!}; // Only start selected so far
              }
              return {}; // Range mode but nothing selected yet
            }
            return tempSelection; // Individual mode
          }
          
          final displayDates = getDisplayDates();
          final statusText = isRangeMode
              ? (rangeStart == null
                  ? 'Start wählen...'
                  : rangeEnd == null
                      ? '${DateFormat('dd.MM').format(rangeStart!)} → Ende wählen...'
                      : '${DateFormat('dd.MM').format(rangeStart!)} – ${DateFormat('dd.MM').format(rangeEnd!)}')
              : '${displayDates.length} ausgewählt';
          
          return AlertDialog(
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Datum auswählen'),
                Text(
                  statusText,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 500,
              height: 450,
              child: Column(
                children: [
                  // Mode toggle inside dialog
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: true, label: Text('Zeitraum'), icon: Icon(Icons.date_range, size: 16)),
                      ButtonSegment(value: false, label: Text('Einzeltage'), icon: Icon(Icons.touch_app, size: 16)),
                    ],
                    selected: {isRangeMode},
                    onSelectionChanged: (selected) {
                      setDialogState(() {
                        isRangeMode = selected.first;
                      });
                    },
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Scrollable calendar
                  Expanded(
                    child: _buildScrollableMonthCalendar(
                      minDate: minDate,
                      maxDate: maxDate,
                      availableDates: availableDates,
                      selectedDates: displayDates,
                onDateTap: (date) {
                  setDialogState(() {
                    if (isRangeMode) {
                      // Range mode: first click = start, second click = end
                      if (rangeStart == null || rangeEnd != null) {
                        // Starting fresh or resetting
                        rangeStart = date;
                        rangeEnd = null;
                      } else {
                        // Setting end
                        if (date.isBefore(rangeStart!)) {
                          // Clicked before start, swap
                          rangeEnd = rangeStart;
                          rangeStart = date;
                        } else {
                          rangeEnd = date;
                        }
                      }
                    } else {
                      // Individual mode: toggle
                      if (tempSelection.contains(date)) {
                        tempSelection.remove(date);
                      } else {
                        tempSelection.add(date);
                      }
                    }
                  });
                },
              ),
            ),
          ],
        ),
      ),
            actions: [
              if (!isRangeMode) ...[
                TextButton(
                  onPressed: () {
                    setDialogState(() => tempSelection.clear());
                  },
                  child: const Text('Alle abwählen'),
                ),
                TextButton(
                  onPressed: () {
                    setDialogState(() {
                      tempSelection.addAll(availableDates);
                    });
                  },
                  child: const Text('Alle auswählen'),
                ),
              ] else ...[
                TextButton(
                  onPressed: () {
                    setDialogState(() {
                      rangeStart = null;
                      rangeEnd = null;
                    });
                  },
                  child: const Text('Zurücksetzen'),
                ),
                // Placeholder for consistent button layout
                const SizedBox(width: 90),
              ],
              const SizedBox(width: 16),
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx, false),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed: (isRangeMode && (rangeStart == null || rangeEnd == null)) ||
                           (!isRangeMode && tempSelection.isEmpty)
                    ? null
                    : () => Navigator.pop(dialogCtx, true),
                child: const Text('Übernehmen'),
              ),
            ],
          );
        },
      ),
    );
    
    if (confirmed == true && mounted) {
      setState(() {
        // Save the mode selection
        state.dateSelectionRangeMode = isRangeMode;
        
        if (isRangeMode && rangeStart != null && rangeEnd != null) {
          state.range = DateTimeRange(start: rangeStart!, end: rangeEnd!);
          _drafts = [];
          _log += 'Zeitraum: ${DateFormat('dd.MM.yyyy').format(rangeStart!)} – ${DateFormat('dd.MM.yyyy').format(rangeEnd!)}\n';
        } else if (!isRangeMode) {
          state.selectedDates = tempSelection;
          state.notifyListeners();
          _drafts = [];
          _log += 'Einzeltage: ${tempSelection.length} Tage ausgewählt\n';
        }
      });
    }
  }
  
  /// Builds a scrollable calendar showing multiple months
  Widget _buildScrollableMonthCalendar({
    required DateTime minDate,
    required DateTime maxDate,
    required Set<DateTime> availableDates,
    required Set<DateTime> selectedDates,
    required void Function(DateTime) onDateTap,
  }) {
    // Generate list of months to display
    final months = <DateTime>[];
    var current = DateTime(minDate.year, minDate.month, 1);
    final lastMonth = DateTime(maxDate.year, maxDate.month, 1);
    while (!current.isAfter(lastMonth)) {
      months.add(current);
      current = DateTime(current.year, current.month + 1, 1);
    }
    
    return ListView.builder(
      itemCount: months.length,
      itemBuilder: (context, index) {
        final month = months[index];
        return _buildMonthGrid(
          month: month,
          availableDates: availableDates,
          selectedDates: selectedDates,
          onDateTap: onDateTap,
        );
      },
    );
  }
  
  /// Builds a single month grid
  Widget _buildMonthGrid({
    required DateTime month,
    required Set<DateTime> availableDates,
    required Set<DateTime> selectedDates,
    required void Function(DateTime) onDateTap,
  }) {
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final firstWeekday = DateTime(month.year, month.month, 1).weekday; // 1=Mon, 7=Sun
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Text(
            DateFormat('MMMM yyyy', 'de_DE').format(month),
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
        ),
        // Weekday header - use same cell width as day cells
        SizedBox(
          width: 308, // 7 days × (40px + 4px margin) = 308px
          child: Wrap(
            children: ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So']
                .map((d) => Container(
                      width: 40,
                      height: 24,
                      margin: const EdgeInsets.all(2),
                      child: Center(
                        child: Text(d, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                      ),
                    ))
                .toList(),
          ),
        ),
        const SizedBox(height: 4),
        // Days grid
        SizedBox(
          width: 308, // 7 days × (40px + 4px margin) = 308px
          child: Wrap(
            children: [
              // Empty cells for days before first of month
              for (var i = 1; i < firstWeekday; i++)
                Container(width: 40, height: 36, margin: const EdgeInsets.all(2)),
              // Actual days
              for (var day = 1; day <= daysInMonth; day++)
                _buildDayCell(
                  date: DateTime(month.year, month.month, day),
                  availableDates: availableDates,
                  selectedDates: selectedDates,
                  onDateTap: onDateTap,
                ),
            ],
          ),
        ),
        const Divider(),
      ],
    );
  }
  
  /// Builds a single day cell
  Widget _buildDayCell({
    required DateTime date,
    required Set<DateTime> availableDates,
    required Set<DateTime> selectedDates,
    required void Function(DateTime) onDateTap,
  }) {
    final normalizedDate = DateTime(date.year, date.month, date.day);
    final isAvailable = availableDates.contains(normalizedDate);
    final isSelected = selectedDates.contains(normalizedDate);
    final isWeekend = date.weekday == 6 || date.weekday == 7;
    
    return GestureDetector(
      onTap: isAvailable ? () => onDateTap(normalizedDate) : null,
      child: Container(
        width: 40,
        height: 36,
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).colorScheme.primary
              : isAvailable
                  ? Theme.of(context).colorScheme.surfaceContainerHighest
                  : null,
          borderRadius: BorderRadius.circular(6),
          border: isAvailable && !isSelected
              ? Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(0.3))
              : null,
        ),
        child: Center(
          child: Text(
            '${date.day}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              color: isSelected
                  ? Theme.of(context).colorScheme.onPrimary
                  : isAvailable
                      ? (isWeekend ? Colors.red[400] : null)
                      : Colors.grey[400],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCalculateButtons(BuildContext context) {
    final state = context.watch<AppState>();
    final locked = !state.isAllConfigured;
    final canCalculate = !locked && state.hasCsv && state.hasIcs;
    final hasDatesSelected = (state.dateSelectionRangeMode && state.range != null) || 
                              (!state.dateSelectionRangeMode && state.selectedDates.isNotEmpty);
    final canCompare = state.hasCsv && hasDatesSelected && !_busy;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Row(children: [
              FilledButton.icon(
                onPressed: canCalculate ? () => _calculate(context) : null,
                icon: const Icon(Icons.calculate),
                label: const Text('Berechnen'),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: locked || _drafts.isEmpty ? null : () => _bookToJira(context),
                icon: const Icon(Icons.send),
                label: const Text('Buchen (Jira)'),
              ),
              const SizedBox(width: 64), // Mehr Abstand
              FilledButton.icon(
                onPressed: canCompare ? () => _compareWithTimetac(context) : null,
                icon: const Icon(Icons.compare_arrows),
                label: const Text('Zeiten vergleichen'),
              ),
              const SizedBox(width: 16),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Vollständig'), icon: Icon(Icons.checklist, size: 16)),
                  ButtonSegment(value: true, label: Text('Nur Ausreißer'), icon: Icon(Icons.warning_amber, size: 16)),
                ],
                selected: {state.settings.timeCheckOutlierModeOnly},
                onSelectionChanged: canCompare ? (selected) {
                  setState(() {
                    state.settings.timeCheckOutlierModeOnly = selected.first;
                  });
                  state.savePrefs();
                } : null,
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Info zu Vergleichsmodi',
                icon: Icon(
                  Icons.info_outline,
                  size: 18,
                  color: canCompare ? null : Colors.grey,
                ),
                onPressed: () {
                  _showInfoDialog(
                    'Vergleichsmodi',
                    '🔍 Vollständig:\n'
                    'Vergleicht alle Aspekte zwischen Timetac und Jira:\n'
                    '• Arbeitsbeginn\n'
                    '• Arbeitsende\n'
                    '• Pausenzeiten\n'
                    '• Netto-Arbeitszeit\n\n'
                    '⚠️ Nur Ausreißer:\n'
                    'Meldet nur Jira-Buchungen die problematisch sind:\n'
                    '• Jira startet VOR dem Timetac-Arbeitsbeginn\n'
                    '• Jira endet NACH dem Timetac-Arbeitsende\n'
                    '• Jira während einer Pause gebucht\n'
                    '• Jira an Abwesenheitstagen (Krank, Urlaub, etc.)\n\n'
                    'Tipp: "Nur Ausreißer" ignoriert, wenn Jira später startet oder früher endet als Timetac.',
                  );
                },
              ),
            ]),
            if (!state.hasCsv || !state.hasIcs)
              const Text(
                'CSV und ICS laden, um „Berechnen" zu aktivieren.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            if (!canCompare && state.hasCsv)
              const Text(
                'Zeitraum wählen, um „Zeiten vergleichen" zu aktivieren.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            if (!canCompare && !state.hasCsv)
              const Text(
                'CSV laden und Zeitraum wählen, um „Zeiten vergleichen" zu aktivieren.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogBox() => Card(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: SelectableText(_log, style: const TextStyle(fontFamily: 'monospace')),
        ),
      );

  Future<void> _showInfoDialog(String title, String body) async {
    await showDialog(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _showErrorDialog(String title, String body) async {
    await showDialog(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  bool _isSameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> _openSettings(BuildContext context) async {
    final s = context.read<AppState>().settings;

    final baseCtl = TextEditingController(text: s.jiraBaseUrl);
    final mailCtl = TextEditingController(text: s.jiraEmail);
    final jiraTokCtl = TextEditingController(text: s.jiraApiToken);
    final meetingCtl = TextEditingController(text: s.meetingIssueKey);
    final fallbackCtl = TextEditingController(text: s.fallbackIssueKey);

    final delimCtl = TextEditingController(text: s.csvDelimiter);
    bool hasHeader = s.csvHasHeader;
    final descCtl = TextEditingController(text: s.csvColDescription);
    final dateCtl = TextEditingController(text: s.csvColDate);
    final startCtl = TextEditingController(text: s.csvColStart);
    final endCtl = TextEditingController(text: s.csvColEnd);
    final durCtl = TextEditingController(text: s.csvColDuration);
    final pauseTotalCtl = TextEditingController(text: s.csvColPauseTotal);
    final pauseRangesCtl = TextEditingController(text: s.csvColPauseRanges);
    final bnaCtl = TextEditingController(text: s.csvColAbsenceTotal);
    final ktCtl = TextEditingController(text: s.csvColSick);
    final ftCtl = TextEditingController(text: s.csvColHoliday);
    final utCtl = TextEditingController(text: s.csvColVacation);
    final zaCtl = TextEditingController(text: s.csvColTimeCompensation);

    final glBaseCtl = TextEditingController(text: s.gitlabBaseUrl);
    final glTokCtl = TextEditingController(text: s.gitlabToken);
    final glProjCtl = TextEditingController(text: s.gitlabProjectIds);
    final glMailCtl = TextEditingController(text: s.gitlabAuthorEmail);
    bool noGitlab = s.noGitlabAccount;

    // Non-Meeting-Hints: Defaults + aktiver Zustand + Custom-Controller
    const defaultsNonMeeting = SettingsModel.defaultNonMeetingHintsList;
    final activeHintsInit = s.nonMeetingHintsList.toSet();

    // aktive Defaults = Schnittmenge von aktiven Hints und Default-Liste
    Set<String> activeDefaults = defaultsNonMeeting.where((d) => activeHintsInit.contains(d)).toSet();

    // Custom-Hints = alles was aktiv ist, aber kein Default ist
    List<TextEditingController> customHintCtrls = activeHintsInit
        .where((h) => !defaultsNonMeeting.contains(h))
        .map((h) => TextEditingController(text: h))
        .toList();

    // Meeting-Regeln
    final meetingRules = List<MeetingRule>.from(s.meetingRules);
    final meetingRulePatternCtrls = <TextEditingController>[];
    final meetingRuleTicketCtrls = <TextEditingController>[];

    for (final r in meetingRules) {
      meetingRulePatternCtrls.add(TextEditingController(text: r.pattern));
      meetingRuleTicketCtrls.add(TextEditingController(text: r.issueKey));
    }

    // Alle vorhandenen Meeting-Titel aus ICS (einmalig für Suggestions)
    final allMeetingTitles = context
        .read<AppState>()
        .icsEvents
        .map((e) => e.summary.trim())
        .where((t) => t.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    // Titel-Ersetzungsregeln
    final titleReplacementRules = List<TitleReplacementRule>.from(s.titleReplacementRules);
    final titleReplacementTriggerCtrls = <TextEditingController>[];
    final titleReplacementReplacementsCtrls = <TextEditingController>[];

    for (final r in titleReplacementRules) {
      titleReplacementTriggerCtrls.add(TextEditingController(text: r.triggerWord));
      titleReplacementReplacementsCtrls.add(TextEditingController(text: r.replacements.join('\n')));
    }

    await showDialog(
      context: context,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => DefaultTabController(
          length: 6,
          child: LayoutBuilder(
            builder: (c, cons) {
              final media = MediaQuery.of(c);
              final maxW = media.size.width - 32;
              final maxH = media.size.height - 32;
              final dialogW = maxW.clamp(360.0, 920.0);
              final dialogH = (maxH * 0.88).clamp(360.0, 820.0);
              final bottomInset = media.viewInsets.bottom;

              void markRebuild(void Function(void Function()) s) => s(() {});

              bool jiraOk() => context.read<AppState>().isJiraConfigured;
              bool timetacOk() => context.read<AppState>().isTimetacConfigured;
              bool gitlabOk() => context.read<AppState>().isGitlabConfigured;
              bool noGitlabAcc() => context.read<AppState>().settings.noGitlabAccount;

              bool jiraTesting = false;
              bool gitlabTesting = false;

              Widget settingsIcon(bool ok, {bool warn = false}) => Icon(
                    warn ? Icons.warning_amber_rounded : (ok ? Icons.check_circle : Icons.cancel),
                    size: 18,
                    color: warn ? Colors.orange : (ok ? Colors.green : Colors.red),
                  );

              Widget sectionTitle(BuildContext ctx, String t) => Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8.0, bottom: 4.0),
                      child: Text(t, style: Theme.of(ctx).textTheme.titleSmall),
                    ),
                  );

              return Dialog(
                insetPadding: const EdgeInsets.all(16),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: dialogW,
                    maxHeight: dialogH,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        // Titelzeile mit Import/Export
                        Row(
                          children: [
                            const Expanded(
                              child: Text('Einstellungen', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                            ),
                            // Global Import Button
                            IconButton(
                              tooltip: 'Alle Einstellungen importieren (JSON)',
                              onPressed: () async {
                                final result = await FilePicker.platform.pickFiles(
                                  type: FileType.custom,
                                  allowedExtensions: ['json'],
                                  dialogTitle: 'Einstellungen importieren',
                                );
                                if (result == null || result.files.isEmpty) return;
                                try {
                                  final file = File(result.files.single.path!);
                                  final jsonStr = await file.readAsString();
                                  final imported = SettingsModel.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
                                  
                                  // Update all controllers
                                  baseCtl.text = imported.jiraBaseUrl;
                                  mailCtl.text = imported.jiraEmail;
                                  jiraTokCtl.text = imported.jiraApiToken;
                                  meetingCtl.text = imported.meetingIssueKey;
                                  fallbackCtl.text = imported.fallbackIssueKey;
                                  delimCtl.text = imported.csvDelimiter;
                                  hasHeader = imported.csvHasHeader;
                                  descCtl.text = imported.csvColDescription;
                                  dateCtl.text = imported.csvColDate;
                                  startCtl.text = imported.csvColStart;
                                  endCtl.text = imported.csvColEnd;
                                  durCtl.text = imported.csvColDuration;
                                  pauseTotalCtl.text = imported.csvColPauseTotal;
                                  pauseRangesCtl.text = imported.csvColPauseRanges;
                                  bnaCtl.text = imported.csvColAbsenceTotal;
                                  ktCtl.text = imported.csvColSick;
                                  ftCtl.text = imported.csvColHoliday;
                                  utCtl.text = imported.csvColVacation;
                                  zaCtl.text = imported.csvColTimeCompensation;
                                  glBaseCtl.text = imported.gitlabBaseUrl;
                                  glTokCtl.text = imported.gitlabToken;
                                  glProjCtl.text = imported.gitlabProjectIds;
                                  glMailCtl.text = imported.gitlabAuthorEmail;
                                  noGitlab = imported.noGitlabAccount;
                                  
                                  // Non-Meeting Keywords
                                  activeDefaults = SettingsModel.defaultNonMeetingHintsList
                                      .where((d) => imported.nonMeetingHintsList.contains(d))
                                      .toSet();
                                  customHintCtrls.clear();
                                  for (final h in imported.nonMeetingHintsList) {
                                    if (!SettingsModel.defaultNonMeetingHintsList.contains(h)) {
                                      customHintCtrls.add(TextEditingController(text: h));
                                    }
                                  }
                                  
                                  // Meeting Rules
                                  meetingRulePatternCtrls.clear();
                                  meetingRuleTicketCtrls.clear();
                                  for (final r in imported.meetingRules) {
                                    meetingRulePatternCtrls.add(TextEditingController(text: r.pattern));
                                    meetingRuleTicketCtrls.add(TextEditingController(text: r.issueKey));
                                  }
                                  
                                  // Title Replacement Rules
                                  titleReplacementTriggerCtrls.clear();
                                  titleReplacementReplacementsCtrls.clear();
                                  for (final r in imported.titleReplacementRules) {
                                    titleReplacementTriggerCtrls.add(TextEditingController(text: r.triggerWord));
                                    titleReplacementReplacementsCtrls.add(TextEditingController(text: r.replacements.join('\n')));
                                  }
                                  
                                  markRebuild(setDlg);
                                  if (ctx.mounted) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      const SnackBar(content: Text('Einstellungen erfolgreich importiert')),
                                    );
                                  }
                                } catch (e) {
                                  if (ctx.mounted) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      SnackBar(content: Text('Fehler beim Import: $e')),
                                    );
                                  }
                                }
                              },
                              icon: const Icon(Icons.file_download),
                            ),
                            // Global Export Button
                            IconButton(
                              tooltip: 'Alle Einstellungen exportieren (JSON)',
                              onPressed: () async {
                                // Build current settings from controllers
                                final exportSettings = SettingsModel(
                                  jiraBaseUrl: baseCtl.text.trim(),
                                  jiraEmail: mailCtl.text.trim(),
                                  jiraApiToken: jiraTokCtl.text.trim(),
                                  meetingIssueKey: meetingCtl.text.trim(),
                                  fallbackIssueKey: fallbackCtl.text.trim(),
                                  csvDelimiter: delimCtl.text.trim(),
                                  csvHasHeader: hasHeader,
                                  csvColDescription: descCtl.text.trim(),
                                  csvColDate: dateCtl.text.trim(),
                                  csvColStart: startCtl.text.trim(),
                                  csvColEnd: endCtl.text.trim(),
                                  csvColDuration: durCtl.text.trim(),
                                  csvColPauseTotal: pauseTotalCtl.text.trim(),
                                  csvColPauseRanges: pauseRangesCtl.text.trim(),
                                  csvColAbsenceTotal: bnaCtl.text.trim(),
                                  csvColSick: ktCtl.text.trim(),
                                  csvColHoliday: ftCtl.text.trim(),
                                  csvColVacation: utCtl.text.trim(),
                                  csvColTimeCompensation: zaCtl.text.trim(),
                                  gitlabBaseUrl: glBaseCtl.text.trim(),
                                  gitlabToken: glTokCtl.text.trim(),
                                  gitlabProjectIds: glProjCtl.text.trim(),
                                  gitlabAuthorEmail: glMailCtl.text.trim(),
                                  noGitlabAccount: noGitlab,
                                  nonMeetingHintsMultiline: [
                                    ...activeDefaults,
                                    ...customHintCtrls.map((c) => c.text.trim()).where((s) => s.isNotEmpty),
                                  ].join('\n'),
                                  meetingRules: [
                                    for (var i = 0; i < meetingRulePatternCtrls.length; i++)
                                      if (meetingRulePatternCtrls[i].text.trim().isNotEmpty &&
                                          meetingRuleTicketCtrls[i].text.trim().isNotEmpty)
                                        MeetingRule(
                                          pattern: meetingRulePatternCtrls[i].text.trim(),
                                          issueKey: meetingRuleTicketCtrls[i].text.trim(),
                                        ),
                                  ],
                                  titleReplacementRules: [
                                    for (var i = 0; i < titleReplacementTriggerCtrls.length; i++)
                                      if (titleReplacementTriggerCtrls[i].text.trim().isNotEmpty &&
                                          titleReplacementReplacementsCtrls[i].text.trim().isNotEmpty)
                                        TitleReplacementRule(
                                          triggerWord: titleReplacementTriggerCtrls[i].text.trim(),
                                          replacements: titleReplacementReplacementsCtrls[i].text
                                              .split(RegExp(r'\r?\n'))
                                              .map((s) => s.trim())
                                              .where((s) => s.isNotEmpty)
                                              .toList(),
                                        ),
                                  ],
                                );
                                
                                final jsonStr = const JsonEncoder.withIndent('  ').convert(exportSettings.toJson());
                                final savePath = await FilePicker.platform.saveFile(
                                  dialogTitle: 'Einstellungen exportieren',
                                  fileName: 'chronos_settings.json',
                                  type: FileType.custom,
                                  allowedExtensions: ['json'],
                                );
                                if (savePath == null) return;
                                try {
                                  await File(savePath).writeAsString(jsonStr);
                                  if (ctx.mounted) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      const SnackBar(content: Text('Einstellungen erfolgreich exportiert')),
                                    );
                                  }
                                } catch (e) {
                                  if (ctx.mounted) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      SnackBar(content: Text('Fehler beim Export: $e')),
                                    );
                                  }
                                }
                              },
                              icon: const Icon(Icons.file_upload),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: 'Schließen',
                              onPressed: () => Navigator.pop(ctx),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),

                        // Tabs mit Live-Status
                        TabBar(
                          isScrollable: true,
                          tabs: [
                            const Tab(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [Text('Meeting-Regeln')],
                              ),
                            ),
                            Tab(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  settingsIcon(jiraOk()),
                                  const SizedBox(width: 6),
                                  const Text('Jira'),
                                ],
                              ),
                            ),
                            Tab(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  settingsIcon(timetacOk()),
                                  const SizedBox(width: 6),
                                  const Text('Timetac'),
                                ],
                              ),
                            ),
                            Tab(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  settingsIcon(gitlabOk(), warn: noGitlabAcc()),
                                  const SizedBox(width: 6),
                                  const Text('GitLab'),
                                ],
                              ),
                            ),
                            const Tab(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text('Non-Meeting Keywords'),
                                ],
                              ),
                            ),
                            const Tab(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text('Titel-Ersetzung'),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),

                        // Flexibler, scrollbarerer Inhalt
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(bottom: bottomInset),
                            child: TabBarView(
                              physics: const NeverScrollableScrollPhysics(),
                              children: [
                                // ------- MEETING-REGELN -------
                                SingleChildScrollView(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    spacing: 8,
                                    children: [
                                      sectionTitle(ctx, 'Meeting-Regeln'),
                                      const Text(
                                        'Regeln werden von oben nach unten geprüft. '
                                        'Die erste passende Regel bestimmt das Ticket. '
                                        'Verglichen wird gegen den Meeting-Titel (Summary).',
                                      ),
                                      const SizedBox(height: 8),
                                      ListView.builder(
                                        shrinkWrap: true,
                                        physics: const NeverScrollableScrollPhysics(),
                                        itemCount: meetingRulePatternCtrls.length,
                                        itemBuilder: (ctx2, i) {
                                          return Card(
                                            margin: const EdgeInsets.symmetric(vertical: 4),
                                            child: Padding(
                                              padding: const EdgeInsets.all(8.0),
                                              child: Row(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  // Up/Down zum Reihenfolge ändern
                                                  Column(
                                                    children: [
                                                      IconButton(
                                                        tooltip: 'Nach oben',
                                                        icon: const Icon(Icons.arrow_upward, size: 18),
                                                        onPressed: i == 0
                                                            ? null
                                                            : () {
                                                                final p = meetingRulePatternCtrls.removeAt(i);
                                                                final t = meetingRuleTicketCtrls.removeAt(i);
                                                                meetingRulePatternCtrls.insert(i - 1, p);
                                                                meetingRuleTicketCtrls.insert(i - 1, t);
                                                                markRebuild(setDlg);
                                                              },
                                                      ),
                                                      IconButton(
                                                        tooltip: 'Nach unten',
                                                        icon: const Icon(Icons.arrow_downward, size: 18),
                                                        onPressed: i == meetingRulePatternCtrls.length - 1
                                                            ? null
                                                            : () {
                                                                final p = meetingRulePatternCtrls.removeAt(i);
                                                                final t = meetingRuleTicketCtrls.removeAt(i);
                                                                meetingRulePatternCtrls.insert(i + 1, p);
                                                                meetingRuleTicketCtrls.insert(i + 1, t);
                                                                markRebuild(setDlg);
                                                              },
                                                      ),
                                                    ],
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: Column(
                                                      crossAxisAlignment: CrossAxisAlignment.start,
                                                      children: [
                                                        Row(
                                                          children: [
                                                            Expanded(
                                                              child: TextField(
                                                                controller: meetingRulePatternCtrls[i],
                                                                decoration: const InputDecoration(
                                                                  labelText: 'Meeting-Titel enthält…',
                                                                ),
                                                                onChanged: (_) => markRebuild(setDlg),
                                                              ),
                                                            ),
                                                            const SizedBox(width: 8),
                                                            if (allMeetingTitles.isNotEmpty)
                                                              PopupMenuButton<String>(
                                                                tooltip: 'Vorschläge aus vorhandenen Meeting-Titeln',
                                                                icon: const Icon(Icons.arrow_drop_down),
                                                                itemBuilder: (_) {
                                                                  final query = meetingRulePatternCtrls[i]
                                                                      .text
                                                                      .trim()
                                                                      .toLowerCase();

                                                                  // Wenn nichts eingegeben → alles, sonst gefiltert
                                                                  final filtered = allMeetingTitles
                                                                      .where((t) {
                                                                        if (query.isEmpty) return true;
                                                                        return t.toLowerCase().contains(query);
                                                                      })
                                                                      .take(25)
                                                                      .toList(); // Hard-Cap, damit das Menü nicht explodiert

                                                                  if (filtered.isEmpty) {
                                                                    return const [
                                                                      PopupMenuItem<String>(
                                                                        enabled: false,
                                                                        value: '',
                                                                        child: Text('Keine passenden Titel gefunden'),
                                                                      ),
                                                                    ];
                                                                  }

                                                                  return filtered
                                                                      .map(
                                                                        (t) => PopupMenuItem<String>(
                                                                          value: t,
                                                                          child: Text(
                                                                            t,
                                                                            overflow: TextOverflow.ellipsis,
                                                                          ),
                                                                        ),
                                                                      )
                                                                      .toList();
                                                                },
                                                                onSelected: (value) {
                                                                  if (value.isEmpty) return;
                                                                  meetingRulePatternCtrls[i].text = value;
                                                                  markRebuild(setDlg);
                                                                },
                                                              ),
                                                          ],
                                                        ),
                                                        const SizedBox(height: 8),
                                                        Row(
                                                          children: [
                                                            Expanded(
                                                              child: TextField(
                                                                controller: meetingRuleTicketCtrls[i],
                                                                decoration: const InputDecoration(
                                                                  labelText: 'Jira-Ticket (z. B. ABC-123)',
                                                                ),
                                                                onChanged: (_) => markRebuild(setDlg),
                                                              ),
                                                            ),
                                                            const SizedBox(width: 8),
                                                            IconButton(
                                                              tooltip: 'Ticket suchen',
                                                              icon: const Icon(Icons.search),
                                                              onPressed: () async {
                                                                final current = meetingRuleTicketCtrls[i].text.trim();
                                                                final picked = await _openIssuePickerDialog(
                                                                  originalKey: current.isEmpty ? 'ABC-123' : current,
                                                                  currentKey: current,
                                                                  title: 'Meeting-Regel: Ticket wählen',
                                                                  showOriginalHint: false,
                                                                );
                                                                if (picked != null && picked.isNotEmpty) {
                                                                  meetingRuleTicketCtrls[i].text = picked;
                                                                  markRebuild(setDlg);
                                                                }
                                                              },
                                                            ),
                                                            IconButton(
                                                              tooltip: 'Regel löschen',
                                                              icon: const Icon(Icons.delete),
                                                              onPressed: () {
                                                                meetingRulePatternCtrls.removeAt(i);
                                                                meetingRuleTicketCtrls.removeAt(i);
                                                                markRebuild(setDlg);
                                                              },
                                                            ),
                                                          ],
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                      const SizedBox(height: 8),
                                      FilledButton.icon(
                                        onPressed: () {
                                          meetingRulePatternCtrls.add(TextEditingController());
                                          meetingRuleTicketCtrls.add(TextEditingController());
                                          markRebuild(setDlg);
                                        },
                                        icon: const Icon(Icons.add),
                                        label: const Text('Neue Regel hinzufügen'),
                                      ),
                                    ],
                                  ),
                                ),

                                // ------- JIRA -------
                                SingleChildScrollView(
                                  child: Column(
                                    spacing: 8,
                                    children: [
                                      sectionTitle(ctx, 'Ticket-Zuordnung'),
                                      Row(children: [
                                        Expanded(
                                          child: TextFormField(
                                            controller: meetingCtl,
                                            decoration: const InputDecoration(
                                              labelText: 'Jira Ticket (Meetings, z. B. ABC-123)',
                                            ),
                                            onChanged: (_) => markRebuild(setDlg),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        IconButton(
                                          tooltip: 'Ticket wählen',
                                          icon: const Icon(Icons.search),
                                          onPressed: () async {
                                            final picked = await _openIssuePickerDialog(
                                              originalKey:
                                                  meetingCtl.text.trim().isEmpty ? 'ABC-123' : meetingCtl.text.trim(),
                                              currentKey: meetingCtl.text.trim(),
                                              title: 'Meeting-Ticket wählen',
                                              showOriginalHint: false,
                                            );
                                            if (picked != null) {
                                              meetingCtl.text = picked;
                                              markRebuild(setDlg);
                                            }
                                          },
                                        ),
                                      ]),
                                      const SizedBox(height: 8),
                                      Row(children: [
                                        Expanded(
                                          child: TextFormField(
                                            controller: fallbackCtl,
                                            decoration: const InputDecoration(
                                              labelText: 'Jira Ticket (Fallback, z. B. ABC-999)',
                                            ),
                                            onChanged: (_) => markRebuild(setDlg),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        IconButton(
                                          tooltip: 'Ticket wählen',
                                          icon: const Icon(Icons.search),
                                          onPressed: () async {
                                            final picked = await _openIssuePickerDialog(
                                              originalKey:
                                                  fallbackCtl.text.trim().isEmpty ? 'ABC-999' : fallbackCtl.text.trim(),
                                              currentKey: fallbackCtl.text.trim(),
                                              title: 'Fallback-Ticket wählen',
                                              showOriginalHint: false,
                                            );
                                            if (picked != null) {
                                              fallbackCtl.text = picked;
                                              markRebuild(setDlg);
                                            }
                                          },
                                        ),
                                      ]),
                                      sectionTitle(ctx, 'Jira Arbeit'),
                                      TextFormField(
                                        decoration: const InputDecoration(
                                          labelText: 'Jira Base URL (https://…atlassian.net)',
                                        ),
                                        controller: baseCtl,
                                        onChanged: (_) => markRebuild(setDlg),
                                      ),
                                      TextFormField(
                                        decoration: const InputDecoration(labelText: 'Jira E-Mail'),
                                        controller: mailCtl,
                                        onChanged: (_) => markRebuild(setDlg),
                                      ),
                                      TextFormField(
                                        decoration: const InputDecoration(labelText: 'Jira API Token'),
                                        controller: jiraTokCtl,
                                        obscureText: true,
                                        onChanged: (_) => markRebuild(setDlg),
                                      ),
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: TextButton.icon(
                                          icon: const Icon(Icons.open_in_new),
                                          label: const Text('Jira-Seite zum Erstellen/Verwalten des API-Tokens öffnen'),
                                          onPressed: () async {
                                            const url = 'https://id.atlassian.com/manage-profile/security/api-tokens';
                                            final uri = Uri.parse(url);
                                            if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
                                              _showErrorDialog(
                                                'Link konnte nicht geöffnet werden',
                                                'Es wurde versucht "$url" zu öffnen',
                                              );
                                            }
                                          },
                                        ),
                                      ),
                                      sectionTitle(ctx, 'Verbindung'),
                                      Row(
                                        children: [
                                          OutlinedButton.icon(
                                            onPressed: () async {
                                              // Eingaben nach settings übernehmen und speichern
                                              final st = context.read<AppState>().settings;
                                              st.jiraBaseUrl = baseCtl.text.trim().replaceAll(RegExp(r'/+$'), '');
                                              st.jiraEmail = mailCtl.text.trim();
                                              st.jiraApiToken = jiraTokCtl.text.trim();
                                              st.meetingIssueKey = meetingCtl.text.trim();
                                              st.fallbackIssueKey = fallbackCtl.text.trim();
                                              await context.read<AppState>().savePrefs();

                                              // Status zurücksetzen und testen
                                              if (context.mounted) {
                                                final app = context.read<AppState>();

                                                // Reset auth status
                                                app.markJiraUnknown();
                                                setDlg(() => jiraTesting = true);
                                                final ok = await app.validateJiraCredentials(requireTickets: false);
                                                setDlg(() => jiraTesting = false);

                                                final credsOk = app._jiraCredentialFieldsFilled;
                                                final ticketsOk = app._jiraTicketFieldsFilled;

                                                String message;

                                                if (!credsOk) {
                                                  // Ohne URL + Mail + Token macht ein Test keinen Sinn
                                                  message = 'Fehler: Jira-Zugangsdaten (URL, E-Mail, API-Token) '
                                                            'fehlen oder sind unvollständig.';
                                                } else if (!ticketsOk) {
                                                  if (ok) {
                                                    // Login ok, Tickets fehlen → Haken ist trotzdem grün
                                                    message = 'Jira-Verbindung erfolgreich!\n\n'
                                                              'Hinweis: Die Tickets für Meetings und Fallback sind '
                                                              'noch nicht befüllt.';
                                                  } else {
                                                    message = 'Fehler: Jira-Verbindung fehlgeschlagen. '
                                                              'Bitte Zugangsdaten prüfen.';
                                                  }
                                                } else {
                                                  // Zugangsdaten + Tickets gefüllt
                                                  message = ok
                                                      ? 'Jira-Verbindung erfolgreich!'
                                                      : 'Fehler: Jira-Verbindung fehlgeschlagen. '
                                                        'Bitte Zugangsdaten prüfen.';
                                                }

                                                _showInfoDialog('Jira-Verbindung', message);
                                              }
                                            },
                                            icon: const Icon(Icons.link),
                                            label: const Text('Verbindung testen'),
                                          ),
                                          const SizedBox(width: 12),
                                          Builder(
                                            builder: (ctx) {
                                              final ok = context.watch<AppState>().jiraAuthOk;
                                              return Row(children: [
                                                Icon(ok ? Icons.check_circle : Icons.cancel,
                                                    size: 18, color: ok ? Colors.green : Colors.red),
                                                const SizedBox(width: 6),
                                                Text(ok ? 'Verbunden' : 'Nicht verbunden'),
                                              ]);
                                            },
                                          ),
                                        ],
                                      ),
                                      if (jiraTesting)
                                        const Padding(
                                          padding: EdgeInsets.only(top: 8.0),
                                          child: LinearProgressIndicator(),
                                        ),
                                      const SizedBox(width: 8),
                                    ],
                                  ),
                                ),

                                // ------- TIMETAC -------
                                SingleChildScrollView(
                                  child: Column(
                                    spacing: 8,
                                    children: [
                                      sectionTitle(ctx, 'CSV (Timetac) – Importkonfiguration'),
                                      Row(children: [
                                        Expanded(
                                          child: TextFormField(
                                            decoration: const InputDecoration(labelText: 'Delimiter (Standard: ;)'),
                                            controller: delimCtl,
                                            onChanged: (_) => markRebuild(setDlg),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Row(children: [
                                            Checkbox(
                                              value: hasHeader,
                                              onChanged: (v) {
                                                hasHeader = v ?? false;
                                                markRebuild(setDlg);
                                              },
                                            ),
                                            const Expanded(child: Text('Erste Zeile enthält Spaltennamen')),
                                          ]),
                                        ),
                                      ]),
                                      TextFormField(
                                        decoration: const InputDecoration(
                                            labelText: 'Spalte: Beschreibung/Aktion (Standard: Kommentar)'),
                                        controller: descCtl,
                                        onChanged: (_) => markRebuild(setDlg),
                                      ),
                                      Row(children: [
                                        Expanded(
                                          child: TextFormField(
                                            decoration:
                                                const InputDecoration(labelText: 'Spalte: Datum (Standard: Datum)'),
                                            controller: dateCtl,
                                            onChanged: (_) => markRebuild(setDlg),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: TextFormField(
                                            decoration:
                                                const InputDecoration(labelText: 'Spalte: Beginn (Standard: K)'),
                                            controller: startCtl,
                                            onChanged: (_) => markRebuild(setDlg),
                                          ),
                                        ),
                                      ]),
                                      Row(children: [
                                        Expanded(
                                          child: TextFormField(
                                            decoration: const InputDecoration(labelText: 'Spalte: Ende (Standard: G)'),
                                            controller: endCtl,
                                            onChanged: (_) => markRebuild(setDlg),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: TextFormField(
                                            decoration:
                                                const InputDecoration(labelText: 'Spalte: Dauer (Standard: GIBA)'),
                                            controller: durCtl,
                                            onChanged: (_) => markRebuild(setDlg),
                                          ),
                                        ),
                                      ]),
                                      Row(children: [
                                        Expanded(
                                          child: TextFormField(
                                            decoration:
                                                const InputDecoration(labelText: 'Spalte: Gesamtpause (Standard: P)'),
                                            controller: pauseTotalCtl,
                                            onChanged: (_) => markRebuild(setDlg),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: TextFormField(
                                            decoration: const InputDecoration(
                                                labelText: 'Spalte: Pausen-Ranges (Standard: Pausen)'),
                                            controller: pauseRangesCtl,
                                            onChanged: (_) => markRebuild(setDlg),
                                          ),
                                        ),
                                      ]),
                                      Row(children: [
                                        Expanded(
                                          child: TextFormField(
                                            decoration: const InputDecoration(
                                                labelText: 'Spalte: Krankheitstage (Standard: KT)'),
                                            controller: ktCtl,
                                            onChanged: (_) => markRebuild(setDlg),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: TextFormField(
                                            decoration:
                                                const InputDecoration(labelText: 'Spalte: Feiertage (Standard: FT)'),
                                            controller: ftCtl,
                                            onChanged: (_) => markRebuild(setDlg),
                                          ),
                                        ),
                                      ]),
                                      Row(children: [
                                        Expanded(
                                          child: TextFormField(
                                            decoration: const InputDecoration(
                                                labelText: 'Spalte: Urlaubsstunden (Standard: UT)'),
                                            controller: utCtl,
                                            onChanged: (_) => markRebuild(setDlg),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: TextFormField(
                                            decoration: const InputDecoration(
                                                labelText: 'Spalte: Gesamte Nichtarbeitszeit (Standard: BNA)'),
                                            controller: bnaCtl,
                                            onChanged: (_) => markRebuild(setDlg),
                                          ),
                                        ),
                                      ]),
                                      TextFormField(
                                        decoration:
                                            const InputDecoration(labelText: 'Spalte: Zeitausgleich (Standard: ZA)'),
                                        controller: zaCtl,
                                        onChanged: (_) => markRebuild(setDlg),
                                      ),
                                    ],
                                  ),
                                ),

                                // ------- GITLAB -------
                                SingleChildScrollView(
                                  child: Column(
                                    spacing: 8,
                                    children: [
                                      sectionTitle(ctx, 'GitLab (für Arbeitszeit Ticket-Automatik)'),
                                      SwitchListTile(
                                        title: const Text('Ich habe keinen GitLab Account'),
                                        subtitle: const Text(
                                            'Deaktiviert die Commit-Suche. App wird nicht gesperrt.'),
                                        value: noGitlab,
                                        onChanged: (v) {
                                          noGitlab = v;
                                          markRebuild(setDlg);
                                        },
                                      ),
                                      if (!noGitlab) ...[
                                        TextFormField(
                                          decoration: const InputDecoration(
                                              labelText: 'GitLab Base URL (https://gitlab.example.com)'),
                                          controller: glBaseCtl,
                                          onChanged: (_) => markRebuild(setDlg),
                                        ),
                                        TextFormField(
                                          decoration: const InputDecoration(labelText: 'GitLab Author E-Mail'),
                                          controller: glMailCtl,
                                          onChanged: (_) => markRebuild(setDlg),
                                        ),
                                        TextFormField(
                                          decoration: const InputDecoration(
                                              labelText: 'GitLab Projekt-IDs (Komma/Leerzeichen getrennt)'),
                                          controller: glProjCtl,
                                          onChanged: (_) => markRebuild(setDlg),
                                        ),
                                        Align(
                                          alignment: Alignment.centerLeft,
                                          child: TextButton.icon(
                                            icon: const Icon(Icons.open_in_new),
                                            label: const Text(
                                                'Gitlab-Übersicht der Projekte öffnen (Auf ein Projekt klicken und dann über die drei Punkte oben rechts die ID kopieren)'),
                                            onPressed: () async {
                                              if (glBaseCtl.text.isNotEmpty) {
                                                var url = glBaseCtl.text.trim();
                                                if (url.endsWith('/')) url = url.substring(0, url.length - 1);
                                                url = '$url/dashboard/projects';
                                                final uri = Uri.parse(url);
                                                if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
                                                  _showErrorDialog(
                                                    'Link konnte nicht geöffnet werden',
                                                    'Es wurde versucht "$url" zu öffnen',
                                                  );
                                                }
                                              } else {
                                                _showErrorDialog(
                                                  'Link konnte nicht geöffnet werden',
                                                  'URL-Feld muss ausgefüllt sein.',
                                                );
                                              }
                                            },
                                          ),
                                        ),
                                        TextFormField(
                                          decoration: const InputDecoration(labelText: 'GitLab PRIVATE-TOKEN'),
                                          controller: glTokCtl,
                                          obscureText: true,
                                          onChanged: (_) => markRebuild(setDlg),
                                        ),
                                        Align(
                                          alignment: Alignment.centerLeft,
                                          child: TextButton.icon(
                                            icon: const Icon(Icons.open_in_new),
                                            label: const Text(
                                              'Gitlab-Seite zum Erstellen/Verwalten des API-Tokens öffnen (NUR READ-API SETZEN)',
                                            ),
                                            onPressed: () async {
                                              if (glBaseCtl.text.isNotEmpty) {
                                                var url = glBaseCtl.text.trim();
                                                if (url.endsWith('/')) url = url.substring(0, url.length - 1);
                                                url = '$url/-/user_settings/personal_access_tokens';
                                                final uri = Uri.parse(url);
                                                if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
                                                  _showErrorDialog(
                                                    'Link konnte nicht geöffnet werden',
                                                    'Es wurde versucht "$url" zu öffnen',
                                                  );
                                                }
                                              } else {
                                                _showErrorDialog(
                                                  'Link konnte nicht geöffnet werden',
                                                  'URL-Feld muss ausgefüllt sein.',
                                                );
                                              }
                                            },
                                          ),
                                        ),
                                      ],
                                      if (!noGitlab)
                                      sectionTitle(ctx, 'Verbindung'),
                                      if (!noGitlab)
                                      Row(
                                        children: [
                                            OutlinedButton.icon(
                                              onPressed: () async {
                                                final st = context.read<AppState>().settings;
                                                // Nur GitLab-Felder speichern für den Test
                                                st.gitlabBaseUrl = glBaseCtl.text.trim().replaceAll(RegExp(r'/+$'), '');
                                                st.gitlabToken = glTokCtl.text.trim();
                                                st.gitlabProjectIds = glProjCtl.text.trim();
                                                st.gitlabAuthorEmail = glMailCtl.text.trim();
                                                st.noGitlabAccount = false; // Ensure we actually test
                                                
                                                await context.read<AppState>().savePrefs();
                                                
                                                if (context.mounted) {
                                                  context.read<AppState>().markGitlabUnknown();
                                                  setDlg(() => gitlabTesting = true);
                                                  final ok = await context.read<AppState>().validateGitlabCredentials();
                                                  setDlg(() => gitlabTesting = false);

                                                  _showInfoDialog(
                                                    'Gitlab-Verbindung',
                                                    ok
                                                        ? 'GitLab-Verbindung erfolgreich'
                                                        : 'GitLab-Verbindung fehlgeschlagen',
                                                  );
                                                }
                                              },
                                              icon: const Icon(Icons.link),
                                              label: const Text('Verbindung testen'),
                                            ),
                                          const SizedBox(width: 12),
                                          Builder(
                                            builder: (_) {
                                              final ok = context.watch<AppState>().gitlabAuthOk;
                                              return Row(
                                                children: [
                                                  Icon(ok ? Icons.check_circle : Icons.cancel,
                                                      size: 18, color: ok ? Colors.green : Colors.red),
                                                  const SizedBox(width: 6),
                                                  Text(ok ? 'Verbunden' : 'Nicht verbunden'),
                                                ],
                                              );
                                            },
                                          ),
                                        ],
                                      ),
                                      if (gitlabTesting)
                                        const Padding(
                                          padding: EdgeInsets.only(top: 8),
                                          child: LinearProgressIndicator(),
                                        ),
                                      const SizedBox(width: 8),
                                    ],
                                  ),
                                ),

                                // ------- NON-MEETING KEYWORDS -------
                                SingleChildScrollView(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    spacing: 8,
                                    children: [
                                      sectionTitle(ctx, 'Nicht-Meeting-Titel (eine Zeile pro Stichwort)'),
                                      const Text(
                                          'Termine wo diese Phrasen vorkommen, werden ignoriert und nicht als Meeting gezählt.'),
                                      Container(
                                        decoration: BoxDecoration(
                                          border: Border.all(color: Theme.of(ctx).dividerColor),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Column(
                                          children: [
                                            Container(
                                              width: double.infinity,
                                              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                                              color: Theme.of(ctx).colorScheme.surfaceContainerHighest.withAlpha(102),
                                              child: const Text(
                                                'Standard-Begriffe (deaktivierte sind durchgestrichen)',
                                                style: TextStyle(fontWeight: FontWeight.w600),
                                              ),
                                            ),
                                            for (final hint in defaultsNonMeeting)
                                              ListTile(
                                                dense: true,
                                                title: Text(
                                                  hint,
                                                  style: TextStyle(
                                                    decoration: activeDefaults.contains(hint)
                                                        ? TextDecoration.none
                                                        : TextDecoration.lineThrough,
                                                    color: activeDefaults.contains(hint)
                                                        ? null
                                                        : Theme.of(ctx).disabledColor,
                                                  ),
                                                ),
                                                trailing: IconButton(
                                                  tooltip: activeDefaults.contains(hint)
                                                      ? 'Diesen Standardbegriff deaktivieren'
                                                      : 'Diesen Standardbegriff wieder aktivieren',
                                                  icon: Icon(
                                                    activeDefaults.contains(hint)
                                                        ? Icons.remove_circle
                                                        : Icons.add_circle,
                                                  ),
                                                  onPressed: () {
                                                    if (activeDefaults.contains(hint)) {
                                                      activeDefaults.remove(hint);
                                                    } else {
                                                      activeDefaults.add(hint);
                                                    }
                                                    markRebuild(setDlg);
                                                  },
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),

                                      const SizedBox(height: 12),

                                      // Eigene (benutzerdefinierte) Begriffe zum Ausschließen
                                      Container(
                                        decoration: BoxDecoration(
                                          border: Border.all(color: Theme.of(ctx).dividerColor),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Column(
                                          children: [
                                            Container(
                                              width: double.infinity,
                                              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                                              color: Theme.of(ctx).colorScheme.surfaceContainerHighest.withAlpha(102),
                                              child: Row(
                                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                children: [
                                                  const Text('Eigene Begriffe',
                                                      style: TextStyle(fontWeight: FontWeight.w600)),
                                                  TextButton.icon(
                                                    icon: const Icon(Icons.add),
                                                    label: const Text('Neue Zeile'),
                                                    onPressed: () {
                                                      customHintCtrls.add(TextEditingController());
                                                      markRebuild(setDlg);
                                                    },
                                                  ),
                                                ],
                                              ),
                                            ),
                                            if (customHintCtrls.isEmpty)
                                              const ListTile(
                                                dense: true,
                                                title: Text('Keine eigenen Begriffe angelegt.'),
                                              ),
                                            for (int i = 0; i < customHintCtrls.length; i++)
                                              ListTile(
                                                dense: true,
                                                title: TextField(
                                                  controller: customHintCtrls[i],
                                                  decoration: const InputDecoration(
                                                    hintText: 'Begriff, z. B. "focus"',
                                                    border: InputBorder.none,
                                                    isDense: true,
                                                  ),
                                                  onChanged: (_) => markRebuild(setDlg),
                                                ),
                                                trailing: IconButton(
                                                  tooltip: 'Diese Zeile löschen',
                                                  icon: const Icon(Icons.delete),
                                                  onPressed: () {
                                                    customHintCtrls.removeAt(i);
                                                    markRebuild(setDlg);
                                                  },
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                // ------- TITEL-ERSETZUNG -------
                                SingleChildScrollView(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    spacing: 8,
                                    children: [
                                      sectionTitle(ctx, 'Titel-Ersetzung (für Förderung)'),
                                      const Text(
                                        'Das Trigger-Wort wird zufällig durch eine der Alternativen ersetzt. '
                                        'Z.B. "Abstimmung" → "Technische Abstimmung"',
                                      ),
                                      const SizedBox(height: 8),

                                      // Vorschläge für Trigger-Wörter
                                      if (TitleReplacementService.suggestedTriggerWords.isNotEmpty)
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 4,
                                          children: [
                                            const Text('Vorschläge: ', style: TextStyle(fontStyle: FontStyle.italic)),
                                            ...TitleReplacementService.suggestedTriggerWords.map(
                                              (w) => ActionChip(
                                                label: Text(w),
                                                onPressed: () {
                                                  // Prüfen ob das Trigger-Wort schon existiert
                                                  final exists = titleReplacementTriggerCtrls.any(
                                                    (c) => c.text.toLowerCase() == w.toLowerCase(),
                                                  );
                                                  if (!exists) {
                                                    titleReplacementTriggerCtrls.add(TextEditingController(text: w));
                                                    final suggestions = TitleReplacementService.suggestedReplacements[w] ?? [];
                                                    titleReplacementReplacementsCtrls.add(
                                                      TextEditingController(text: suggestions.join('\n')),
                                                    );
                                                    markRebuild(setDlg);
                                                  }
                                                },
                                              ),
                                            ),
                                          ],
                                        ),

                                      const SizedBox(height: 12),

                                      // Liste der Regeln
                                      ListView.builder(
                                        shrinkWrap: true,
                                        physics: const NeverScrollableScrollPhysics(),
                                        itemCount: titleReplacementTriggerCtrls.length,
                                        itemBuilder: (ctx2, i) {
                                          return Card(
                                            margin: const EdgeInsets.symmetric(vertical: 6),
                                            child: Padding(
                                              padding: const EdgeInsets.all(12.0),
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  Row(
                                                    children: [
                                                      Expanded(
                                                        child: TextField(
                                                          controller: titleReplacementTriggerCtrls[i],
                                                          decoration: const InputDecoration(
                                                            labelText: 'Trigger-Wort (z.B. "Abstimmung")',
                                                            border: OutlineInputBorder(),
                                                          ),
                                                          onChanged: (_) => markRebuild(setDlg),
                                                        ),
                                                      ),
                                                      const SizedBox(width: 8),
                                                      IconButton(
                                                        tooltip: 'Regel löschen',
                                                        icon: const Icon(Icons.delete, color: Colors.red),
                                                        onPressed: () {
                                                          titleReplacementTriggerCtrls.removeAt(i);
                                                          titleReplacementReplacementsCtrls.removeAt(i);
                                                          markRebuild(setDlg);
                                                        },
                                                      ),
                                                    ],
                                                  ),
                                                  const SizedBox(height: 12),
                                                  TextField(
                                                    controller: titleReplacementReplacementsCtrls[i],
                                                    decoration: const InputDecoration(
                                                      labelText: 'Ersetzungen (eine pro Zeile)',
                                                      border: OutlineInputBorder(),
                                                      alignLabelWithHint: true,
                                                    ),
                                                    maxLines: 4,
                                                    onChanged: (_) => markRebuild(setDlg),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          );
                                        },
                                      ),

                                      if (titleReplacementTriggerCtrls.isEmpty)
                                        const Padding(
                                          padding: EdgeInsets.symmetric(vertical: 16),
                                          child: Text(
                                            'Keine Ersetzungsregeln vorhanden. '
                                            'Klicke auf einen Vorschlag oben oder füge eine neue Regel hinzu.',
                                            style: TextStyle(fontStyle: FontStyle.italic, color: Colors.grey),
                                          ),
                                        ),

                                      const SizedBox(height: 8),
                                      FilledButton.icon(
                                        onPressed: () {
                                          titleReplacementTriggerCtrls.add(TextEditingController());
                                          titleReplacementReplacementsCtrls.add(TextEditingController());
                                          markRebuild(setDlg);
                                        },
                                        icon: const Icon(Icons.add),
                                        label: const Text('Neue Regel hinzufügen'),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(height: 8),

                        // Aktionen
                        Row(
                          children: [
                            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Schließen')),
                            const Spacer(),
                            FilledButton(
                              onPressed: () async {
                                final app = context.read<AppState>();
                                final st = app.settings;

                                // Jira
                                st.jiraBaseUrl = baseCtl.text.trim().replaceAll(RegExp(r'/+$'), '');
                                st.jiraEmail = mailCtl.text.trim();
                                st.jiraApiToken = jiraTokCtl.text.trim();
                                st.meetingIssueKey = meetingCtl.text.trim();
                                st.fallbackIssueKey = fallbackCtl.text.trim();

                                // CSV
                                st.csvDelimiter = delimCtl.text.trim().isEmpty ? ';' : delimCtl.text.trim();
                                st.csvHasHeader = hasHeader;
                                st.csvColDescription = descCtl.text.trim();
                                st.csvColDate = dateCtl.text.trim();
                                st.csvColStart = startCtl.text.trim();
                                st.csvColEnd = endCtl.text.trim();
                                st.csvColDuration = durCtl.text.trim();
                                st.csvColPauseTotal = pauseTotalCtl.text.trim();
                                st.csvColPauseRanges = pauseRangesCtl.text.trim();
                                st.csvColAbsenceTotal = bnaCtl.text.trim();
                                st.csvColSick = ktCtl.text.trim();
                                st.csvColHoliday = ftCtl.text.trim();
                                st.csvColVacation = utCtl.text.trim();
                                st.csvColTimeCompensation = zaCtl.text.trim();

                                // GitLab
                                st.gitlabBaseUrl = glBaseCtl.text.trim().replaceAll(RegExp(r'/+$'), '');
                                st.gitlabToken = glTokCtl.text.trim();
                                st.gitlabProjectIds = glProjCtl.text.trim();
                                st.gitlabAuthorEmail = glMailCtl.text.trim();
                                st.noGitlabAccount = noGitlab;

                                // Meeting-Regeln übernehmen
                                final newMeetingRules = <MeetingRule>[];
                                for (var i = 0; i < meetingRulePatternCtrls.length; i++) {
                                  final pattern = meetingRulePatternCtrls[i].text.trim();
                                  final ticket = meetingRuleTicketCtrls[i].text.trim();
                                  if (pattern.isEmpty || ticket.isEmpty) continue;
                                  newMeetingRules.add(
                                    MeetingRule(pattern: pattern, issueKey: ticket),
                                  );
                                }
                                st.meetingRules = newMeetingRules;

                                // Non-Meeting Keywords übernehmen
                                final allHints = <String>[
                                  ...activeDefaults,
                                  ...customHintCtrls.map((c) => c.text.trim()).where((s) => s.isNotEmpty),
                                ];
                                st.nonMeetingHintsMultiline = allHints.join('\n');

                                // Titel-Ersetzungsregeln übernehmen
                                final newTitleReplacementRules = <TitleReplacementRule>[];
                                for (var i = 0; i < titleReplacementTriggerCtrls.length; i++) {
                                  final trigger = titleReplacementTriggerCtrls[i].text.trim();
                                  final replacementsText = titleReplacementReplacementsCtrls[i].text.trim();
                                  if (trigger.isEmpty || replacementsText.isEmpty) continue;
                                  final replacements = replacementsText
                                      .split(RegExp(r'\r?\n'))
                                      .map((s) => s.trim())
                                      .where((s) => s.isNotEmpty)
                                      .toList();
                                  if (replacements.isEmpty) continue;
                                  newTitleReplacementRules.add(
                                    TitleReplacementRule(triggerWord: trigger, replacements: replacements),
                                  );
                                }
                                st.titleReplacementRules = newTitleReplacementRules;

                                await app.savePrefs();

                                // Validieren
                                app.markJiraUnknown();
                                app.markGitlabUnknown();
                                final jiraOkay = await app.validateJiraCredentials();
                                final gitlabOkay = await app.validateGitlabCredentials();
                                if (!ctx.mounted || !context.mounted) return;

                                if (jiraOkay && gitlabOkay) {
                                  Navigator.of(ctx).pop(); // Settings schließen
                                  ScaffoldMessenger.of(context)
                                      .showSnackBar(const SnackBar(content: Text('Gespeichert und verbunden')));
                                  return;
                                }

                                // Fehlerfall: Settings-Dialog offen lassen und Fehlgrund anzeigen
                                final problems = <String>[];

                                // Jira-Fehler differenziert
                                if (!jiraOkay) {
                                  final jiraCredsOk = app._jiraCredentialFieldsFilled;
                                  final jiraTicketsOk = app._jiraTicketFieldsFilled;

                                  if (!jiraCredsOk && !jiraTicketsOk) {
                                    problems.add(
                                      'Jira: Zugangsdaten (Base-URL, E-Mail, API-Token) '
                                      'UND Tickets (Meeting/Fallback) sind nicht vollständig.',
                                    );
                                  } else if (!jiraCredsOk) {
                                    problems.add(
                                      'Jira: Zugangsdaten (Base-URL, E-Mail, API-Token) fehlen '
                                      'oder sind ungültig.',
                                    );
                                  } else if (!jiraTicketsOk) {
                                    problems.add(
                                      'Jira: Verbindung wäre möglich, aber die Tickets für '
                                      'Meetings und Fallback sind nicht gesetzt.',
                                    );
                                  } else {
                                    problems.add(
                                      'Jira: Verbindungstest ist fehlgeschlagen. Bitte Zugangsdaten '
                                      'und Berechtigungen prüfen.',
                                    );
                                  }
                                }

                                // GitLab-Fehler differenziert
                                if (!gitlabOkay) {
                                  final gitlabFieldsOk = app._gitlabFieldsFilled;

                                  if (!gitlabFieldsOk) {
                                    problems.add(
                                      'GitLab: URL, PRIVATE-TOKEN oder Projekt-IDs sind nicht vollständig.',
                                    );
                                  } else {
                                    problems.add(
                                      'GitLab: Verbindungstest ist fehlgeschlagen. Bitte Base-URL, Token '
                                      'und Projekt-IDs (sowie Token-Rechte) prüfen.',
                                    );
                                  }
                                }

                                final buffer = StringBuffer()
                                  ..writeln('Die Einstellungen wurden gespeichert,')
                                  ..writeln('aber es gab Probleme bei den Verbindungen:')
                                  ..writeln()
                                  ..writeln(problems.join('\n\n'));

                                await _showErrorDialog('Verbindung fehlgeschlagen', buffer.toString());
                              },
                              child: const Text('Speichern'),
                            )
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _calculate(BuildContext context) async {
    final state = context.read<AppState>();
    final jira = JiraApi(
      baseUrl: state.settings.jiraBaseUrl,
      email: state.settings.jiraEmail,
      apiToken: state.settings.jiraApiToken,
    );

    setState(() {
      _busy = true;
      _log += 'Berechne…\n';
      _drafts = [];
    });

    try {
      clearIcsDayCache(); // defensiv

      // CSV-Tage ermitteln
      final csvDaysSet = state.timetac.map((t) => DateTime(t.date.year, t.date.month, t.date.day)).toSet();
      if (csvDaysSet.isEmpty) {
        _log += 'Hinweis: Keine CSV-Daten geladen.\n';
        setState(() => _busy = false);
        return;
      }

      var csvDays = csvDaysSet.toList()..sort();
      late DateTime rangeStart, rangeEnd;
      
      final effectiveDates = state.effectiveSelectedDates;

      if (effectiveDates.isNotEmpty) {
        final sortedDates = effectiveDates.toList()..sort();
        rangeStart = sortedDates.first;
        rangeEnd = sortedDates.last;
        
        // In individual days mode, filter CSV days to only selected dates
        if (!state.dateSelectionRangeMode) {
          csvDays = csvDays.where((d) => effectiveDates.contains(d)).toList();
        } else {
          csvDays = csvDays.where((d) => !d.isBefore(rangeStart) && !d.isAfter(rangeEnd)).toList();
        }
        
        _log += state.dateSelectionRangeMode
            ? 'Zeitraum aktiv: ${DateFormat('dd.MM.yyyy').format(rangeStart)} – ${DateFormat('dd.MM.yyyy').format(rangeEnd)}\n'
            : 'Einzeltage: ${effectiveDates.length} Tage ausgewählt\n';
      } else {
        rangeStart = csvDays.first;
        rangeEnd = csvDays.last;
      }

      _log += 'CSV-Tage erkannt: ${csvDaysSet.length} (im Zeitraum: ${csvDays.length})\n';
      if (csvDays.isEmpty) {
        _log += 'Hinweis: Im gewählten Zeitraum wurden keine CSV-Tage gefunden.\n';
        setState(() => _busy = false);
        return;
      }

      // Meetings für Zeitraum vorbereiten (Fast-Cache)
      prepareUserMeetingsRange(
        allEvents: state.icsEvents,
        userEmail: state.settings.jiraEmail,
        from: rangeStart,
        to: rangeEnd,
      );

      // GitLab vorbereiten
      final s = state.settings;
      final lookbackStart = rangeStart.subtract(Duration(days: s.gitlabLookbackDays));
      final until = rangeEnd.add(const Duration(days: 1));
      final authorEmails = _emailsFromSettings(s);

      List<_CT> ordered = [];
      state.gitlabCommits = [];

      if (!s.noGitlabAccount && s.gitlabBaseUrl.isNotEmpty && s.gitlabToken.isNotEmpty && s.gitlabProjectIds.isNotEmpty) {
        final api = GitlabApi(baseUrl: s.gitlabBaseUrl, token: s.gitlabToken);
        final ids =
            s.gitlabProjectIds.split(RegExp(r'[,\s]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

        final allFetched = <GitlabCommit>[];
        final perProject = <String, int>{};
        int totalFetched = 0;

        for (final id in ids) {
          final commits = await api.fetchCommits(
            projectId: id,
            since: lookbackStart,
            until: until,
            authorEmail: null, // clientseitig filtern
          );
          allFetched.addAll(commits);
          totalFetched += commits.length;
          perProject[id] = (perProject[id] ?? 0) + commits.length;
        }

        state.gitlabCommits = allFetched;

        _log += 'GitLab-Commits geladen: $totalFetched\n';
        for (final id in ids) {
          _log += '  • Projekt $id: ${perProject[id] ?? 0}\n';
        }

        final before = state.gitlabCommits.length;
        final filtered = _filterCommitsByEmails(state.gitlabCommits, authorEmails);
        final after = filtered.length;
        _log += 'Commits nach Autor-Filter: $after (von $before) — Filter: '
            '${authorEmails.isEmpty ? '(leer → Jira-Mail verwendet)' : authorEmails.join(', ')}\n';

        ordered = _sortedCommitsWithTickets(filtered);
        _log += 'Commits mit Ticket-Präfix (nach Filter): ${ordered.length}\n';
      } else {
        _log += 'GitLab deaktiviert – kein Commit-basiertes Routing.\n';
      }

      final allDrafts = <DraftLog>[];

      for (final day in csvDays) {
        if (ordered.isNotEmpty) {
          _logCommitsForDay(day, ordered, (s) => _log += s);
        }

        // Arbeitsfenster
        final workWindows = state.workWindowsForDay(day);
        final productiveDur = workWindows.fold<Duration>(Duration.zero, (p, w) => p + w.duration);

        // CSV-Zeilen des Tages
        final rowsForDay = state.timetac
            .where((r) => r.date.year == day.year && r.date.month == day.month && r.date.day == day.day)
            .toList();

        final ignoreOutlook = productiveDur == Duration.zero ||
            rowsForDay.any((r) {
              final d = r.description.toLowerCase();
              return d.contains('urlaub') || d.contains('feiertag') || d.contains('krank') || d.contains('abwesen');
            });

        // Meetings schneiden und als Drafts
        final meetingCutters = <WorkWindow>[];
        final meetingDrafts = <DraftLog>[];
        if (!ignoreOutlook) {
          final eventsRaw = meetingsForUserOnDayFast(
            day: day,
            userEmail: state.settings.jiraEmail,
          );

          // Zusätzlicher Schutz: offensichtliche Absagen/Ablehnungen raus
          final events = eventsRaw.where((e) => !e.isLikelyCancelledOrDeclined).toList();

          // Optionales Logging – hilft beim Debuggen
          final skipped = eventsRaw.length - events.length;
          if (skipped > 0) {
            _log += '  (Info) $skipped Meeting(s) wegen Absage/Ablehnung ignoriert.\n';
          }

          for (final e in events) {
            meetingCutters.add(WorkWindow(e.start, e.end));

            final titleText = e.summary.trim();
            final issueKeyForMeeting = state.resolveMeetingIssueKeyForTitle(titleText);

            for (final w in workWindows) {
              final s1 = e.start.isAfter(w.start) ? e.start : w.start;
              final e1 = e.end.isBefore(w.end) ? e.end : w.end;
              if (e1.isAfter(s1)) {
                final titleSuffix = titleText.isEmpty ? '' : '– $titleText';
                final noteText = 'Meeting $titleSuffix';
                
                // Titel-Ersetzung anwenden
                final titleRules = state.settings.titleReplacementRules;
                final (:newTitle, :originalTitle) = TitleReplacementService.applyReplacement(noteText, titleRules);
                
                meetingDrafts.add(
                  DraftLog(
                    start: s1,
                    end: e1,
                    issueKey: issueKeyForMeeting,
                    note: newTitle,
                    originalNote: originalTitle,
                  ),
                );
              }
            }
            }
            
            // Überlappungen innerhalb der Meetings auflösen
            try {
              final resolved = _resolveMeetingOverlaps(meetingDrafts);
              meetingDrafts.clear();
              meetingDrafts.addAll(resolved);
            } catch (e) {
              _log += 'FEHLER beim Auflösen von Meeting-Überlappungen: $e\n';
            }
          }

        // Arzttermine als Pause behandeln, nur wenn keine KT/FT/UT/ZA vorliegen
        final ktDays = rowsForDay.fold<double>(0.0, (p, r) => p + r.sickDays);
        final ftDays = rowsForDay.fold<double>(0.0, (p, r) => p + r.holidayDays);
        final utHours = rowsForDay.fold<Duration>(Duration.zero, (p, r) => p + r.vacationHours);
        final zaHours = rowsForDay.fold<Duration>(Duration.zero, (p, r) => p + r.timeCompensationHours);
        final doctor = (ktDays == 0.0 && ftDays == 0.0 && utHours == Duration.zero && zaHours == Duration.zero)
            ? rowsForDay.fold<Duration>(Duration.zero, (p, r) => p + r.absenceTotal)
            : Duration.zero;

        // Rest = Arbeitsfenster minus Meetings
        final restPieces = <WorkWindow>[];
        for (final w in workWindows) {
          restPieces.addAll(subtractIntervals(w, meetingCutters));
        }

        // Arztbesuch vom Rest abziehen? NEIN!
        // Timetac "Ende" ist oft der Zeitpunkt des Gehens. Die "Bezahlte Nichtarbeitszeit" kommt OBENDRAUF
        // (verlängert den Tag). Wenn wir sie abziehen, kürzen wir die echte Anwesenheit weg.
        // Daher: trimmedRest = restPieces (ungekürzt).
        final trimmedRest = restPieces;

        // Rest auf Tickets verteilen
        final restDrafts = <DraftLog>[];

        if (trimmedRest.isEmpty) {
          // nichts mehr übrig
        } else if (!state.settings.noGitlabAccount && ordered.isNotEmpty) {
          // GitLab aktiv und Commits vorhanden → wie bisher über Commits routen
          restDrafts.addAll(
            _assignRestPiecesByCommits(
              pieces: trimmedRest,
              ordered: ordered,
              note: 'Arbeit',
              log: (s) => _log += s,
            ),
          );
        } else {
          // KEIN GitLab (noGitlabAccount == true) ODER keine Commits → alles aufs Fallback-Ticket buchen
          final fallbackKey = state.settings.fallbackIssueKey;

          for (final piece in trimmedRest) {
            restDrafts.add(
              DraftLog(
                start: piece.start,
                end: piece.end,
                issueKey: fallbackKey,
                note: 'Arbeit',
              ),
            );
          }

          _log += 'Restarbeit ohne GitLab-Commits: '
              '${restDrafts.length} Worklog(s) auf $fallbackKey.\n';
        }

        // Pausen als DraftLogs für die Anzeige (werden nicht gebucht)
        final pauseDrafts = <DraftLog>[];
        for (final row in rowsForDay) {
          for (final pr in row.pauses) {
            pauseDrafts.add(DraftLog(
              start: pr.start,
              end: pr.end,
              issueKey: '',
              note: 'Pause',
              isPause: true,
            ));
          }
        }

        // Arzttermine aus Timetac erkennen (absenceTotal > 0)
        // ABER: Nur wenn es kein voller Krankenstand/Feiertag/Urlaubstag ist
        // UND: Nur wenn die bezahlte Nichtarbeitszeit nicht den ganzen Tag ausmacht
        final doctorDrafts = <DraftLog>[];
        final isFullSickDay = rowsForDay.any((r) => r.sickDays > 0);
        final isFullHoliday = rowsForDay.any((r) => r.holidayDays > 0);
        final isFullVacation = rowsForDay.any((r) => r.vacationHours.inHours >= 8);
        final isFullDayPaidNonWork = doctor >= productiveDur && productiveDur > Duration.zero;
        final noWorkWindow = productiveDur == Duration.zero;
        
        if (!isFullSickDay && !isFullHoliday && !isFullVacation && !isFullDayPaidNonWork && !noWorkWindow) {
          for (final r in rowsForDay) {
            if (r.absenceTotal > Duration.zero) {
               final doctorDuration = r.absenceTotal;
               
               // Sammle alle bisherigen Drafts (ohne Pausen) sortiert
               final existingDrafts = [...meetingDrafts, ...restDrafts]
                 ..sort((a, b) => a.start.compareTo(b.start));
               
               DateTime? gapStart;
               DateTime? gapEnd;
               
               // Suche nach einer Lücke, die groß genug ist
               if (existingDrafts.length >= 2) {
                 for (int i = 0; i < existingDrafts.length - 1; i++) {
                   final currentEnd = existingDrafts[i].end;
                   final nextStart = existingDrafts[i + 1].start;
                   final gapDuration = nextStart.difference(currentEnd);
                   
                   // Prüfe ob Lücke groß genug ist (mit etwas Puffer)
                   if (gapDuration >= doctorDuration) {
                     gapStart = currentEnd;
                     gapEnd = currentEnd.add(doctorDuration);
                     break;
                   }
                 }
               }
               
               // Wenn keine passende Lücke gefunden: Am Ende des Arbeitstages
               if (gapStart == null) {
                 final endOfWork = r.end ?? (existingDrafts.isNotEmpty 
                   ? existingDrafts.last.end 
                   : DateTime(day.year, day.month, day.day, 17, 0));
                 gapStart = endOfWork;
                 gapEnd = endOfWork.add(doctorDuration);
               }
               
               // Korrektur: Arzttermin darf nicht mit Pause überlappen (sollte danach starten)
               for (final p in r.pauses) {
                 // Prüfe auf Überlappung
                 if (gapStart!.isBefore(p.end) && gapEnd!.isAfter(p.start)) {
                   // Wenn Start in oder vor Pause liegt -> Verschiebe auf Pausenende
                   if (p.end.isAfter(gapStart!)) {
                     gapStart = p.end;
                     gapEnd = gapStart!.add(doctorDuration);
                   }
                 }
               }
               
               doctorDrafts.add(DraftLog(
                 start: gapStart!,
                 end: gapEnd!,
                 issueKey: '',
                 note: 'Bezahlte Nichtarbeitszeit',
                 isDoctorAppointment: true,
               ));
            }
          }
        }

        // Drafts des Tages zusammenführen
        final dayDrafts = <DraftLog>[
          ...meetingDrafts,
          ...restDrafts,
          ...pauseDrafts,
          ...doctorDrafts,
        ]..sort((a, b) => a.start.compareTo(b.start));

        // Ticket-Overrides anwenden, falls gesetzt
        final withOverrides = dayDrafts.map((d) {
          final id = _draftKey(d);
          final overridden = _issueOverrides[id];
          if (overridden != null && overridden.trim().isNotEmpty && overridden != d.issueKey) {
            return DraftLog(
              start: d.start, 
              end: d.end, 
              issueKey: overridden, 
              note: d.note,
              isPause: d.isPause,
              isDoctorAppointment: d.isDoctorAppointment,
              isManuallyModified: d.isManuallyModified,
              deltaState: d.deltaState,
            );
          }
          return d;
        }).toList();

        allDrafts.addAll(withOverrides.where((d) => d.duration.inMinutes >= 1));

        // Logging Tageszusammenfassung
        final meetingDur = meetingDrafts.fold<Duration>(Duration.zero, (p, d) => p + d.duration);
        final dayTicketCount =
            ordered.where((c) => c.at.year == day.year && c.at.month == day.month && c.at.day == day.day).length;

        _log += 'Tag ${DateFormat('dd.MM.yyyy').format(day)}: '
            'Timetac=${formatDuration(productiveDur)}, '
            'Meetings=${formatDuration(meetingDur)}, '
            '${ignoreOutlook ? 'Outlook ignoriert' : 'Outlook berücksichtigt'}, '
            '${ordered.isNotEmpty ? 'GitLab aktiv ($dayTicketCount/${ordered.length})' : 'GitLab aus'}\n';
      }

      // -------- Summaries laden (nur für Anzeige) --------
      final overrideKeys = _issueOverrides.values.where((e) => e.trim().isNotEmpty).toSet();
      final nonMeetingKeys = allDrafts
          .where((d) => !d.isPause && d.issueKey.isNotEmpty && d.issueKey != state.settings.meetingIssueKey)
          .map((d) => d.issueKey)
          .toSet();

      final needSummaries = {...nonMeetingKeys, ...overrideKeys};
      Map<String, String> summaries = {};
      if (needSummaries.isNotEmpty) {
        summaries = await jira.fetchSummariesByKeys(needSummaries);
        _log += 'Jira Summaries geholt: ${summaries.length}/${needSummaries.length}\n';
      }
      _jiraSummaryCache = summaries;

      // Notes für Arbeits-Blöcke (GitLab-basiert) mit Ticket-Titel ersetzen
    for (final d in allDrafts) {
      if (d.note == 'Arbeit') {
        final sum = summaries[d.issueKey];
        if (sum != null && sum.isNotEmpty) {
          d.note = 'Arbeit – $sum';
        }
      }
    }

      await state.applyDeltaModeToDrafts(allDrafts);

      // Drafts direkt übernehmen, note NICHT mit Titeln anreichern
      setState(() {
        _drafts = allDrafts;
        _originalDrafts = allDrafts.map((d) => d.copy()).toList();
      });

      if (allDrafts.isEmpty) {
        _log += 'Hinweis: Keine Worklogs erzeugt. Prüfe CSV/ICS, Zeitraum und Commit-Filter.\n';
      }

      _log += 'Drafts: ${allDrafts.length}\n';
    } catch (e, st) {
      _log += 'EXCEPTION in Berechnung: $e\n$st\n';
    } finally {
      setState(() {
        _tabIndex = 2; // Wechsle zu "Geplante Worklogs" Tab
        _busy = false;
      });
    }
  }

  Future<String?> _openIssuePickerDialog({
    required String originalKey,
    String? currentKey,
    String title = 'Jira Ticket wählen',
    bool showOriginalHint = true,
  }) async {
    final txtCtl = TextEditingController(text: currentKey ?? originalKey);
    List<JiraIssueLight> results = [];
    bool loading = false;
    bool firedInitialSearch = false;
    Timer? deb;

    final s = context.read<AppState>().settings;
    final jira = JiraApi(baseUrl: s.jiraBaseUrl, email: s.jiraEmail, apiToken: s.jiraApiToken);

    Future<void> runSearch(String q, void Function(void Function()) setDlg) async {
      if (q.trim().isEmpty) {
        setDlg(() {});
        return;
      }
      loading = true;
      setDlg(() {});
      results = await jira.searchIssues(q.trim());
      loading = false;
      setDlg(() {});
    }

    return showDialog<String>(
      context: context,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          // Beim ersten Build direkt einmal suchen, wenn Feld nicht leer ist.
          if (!firedInitialSearch) {
            firedInitialSearch = true;
            if (txtCtl.text.trim().isNotEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                runSearch(txtCtl.text.trim(), setDlg);
              });
            }
          }

          return AlertDialog(
            title: Text(title),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 700, maxHeight: 520),
              child: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showOriginalHint && originalKey.isNotEmpty) // <— nur wenn erlaubt
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline, size: 18),
                            const SizedBox(width: 6),
                            Flexible(child: Text('Original erkannt: $originalKey')),
                          ],
                        ),
                      ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: txtCtl,
                      decoration: const InputDecoration(
                        labelText: 'Suche nach Key (ABC-123) oder Titel',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (v) {
                        deb?.cancel();
                        deb = Timer(const Duration(milliseconds: 350), () => runSearch(v, setDlg));
                      },
                      onSubmitted: (v) => runSearch(v, setDlg),
                    ),
                    const SizedBox(height: 8),
                    if (loading) const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Material(
                        child: results.isEmpty
                            ? const Center(child: Text('Keine Treffer'))
                            : ListView.separated(
                                itemCount: results.length,
                                separatorBuilder: (_, __) => const Divider(height: 1),
                                itemBuilder: (_, i) {
                                  final it = results[i];
                                  return ListTile(
                                    dense: true,
                                    leading: const Icon(Icons.bug_report),
                                    title: Text(it.key),
                                    subtitle: Text(it.summary, maxLines: 2, overflow: TextOverflow.ellipsis),
                                    onTap: () => Navigator.of(ctx).pop(it.key),
                                  );
                                },
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Abbrechen')),
              if (showOriginalHint)
                TextButton(
                    onPressed: () => Navigator.of(ctx).pop(originalKey),
                    child: const Text('Original erkanntes Ticket nutzen')),
            ],
          );
        },
      ),
    );
  }

  Future<void> _bookToJira(BuildContext context) async {
    final state = context.read<AppState>();

    if (_drafts.isEmpty) {
      setState(() => _log += 'Keine Worklogs zu senden.\n');
      await _showInfoDialog('Buchen', 'Keine Worklogs zu senden.');
      return;
    }
    if (!state.isJiraConfigured) {
      setState(() => _log += 'FEHLER: Jira-Zugangsdaten fehlen.\n');
      await _showErrorDialog('Buchen fehlgeschlagen', 'Jira-Zugangsdaten fehlen.');
      return;
    }

    setState(() {
      _busy = true;
      _log += 'Sende an Jira…\n';
    });

    // Progress-Dialog mit ValueNotifier für Live-Updates
    final progressNotifier = ValueNotifier<(int, int, String)>((0, 1, 'Vorbereitung...'));
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Buche Worklogs...'),
          content: ValueListenableBuilder<(int, int, String)>(
            valueListenable: progressNotifier,
            builder: (_, value, __) {
              final (current, total, label) = value;
              final progress = total > 0 ? current / total : 0.0;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: progress),
                  const SizedBox(height: 16),
                  Text('Eintrag $current / $total'),
                  const SizedBox(height: 8),
                  Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              );
            },
          ),
        ),
      ),
    );

    try {
      final jira = JiraApi(
        baseUrl: state.settings.jiraBaseUrl,
        email: state.settings.jiraEmail,
        apiToken: state.settings.jiraApiToken,
      );
      final worklogApi = JiraWorklogApi(
        baseUrl: state.settings.jiraBaseUrl,
        email: state.settings.jiraEmail,
        apiToken: state.settings.jiraApiToken,
      );

      // ---------- Delta-Filter anwenden ----------
      final skippedDrafts = <DraftLog>[];
      final draftsToSend = <DraftLog>[];

      for (final d in _drafts) {
        // Pausen und Arzttermine niemals buchen
        if (d.shouldSkipBooking) continue;
        
        final isDeltaProtected =
            state.deltaModeEnabled && (d.deltaState == DeltaState.duplicate || d.deltaState == DeltaState.overlap);

        if (isDeltaProtected) {
          skippedDrafts.add(d);
        } else {
          draftsToSend.add(d);
        }
      }

      // Wenn alles nur Duplikat/Overlap ist → nichts senden, Infos anzeigen
      if (draftsToSend.isEmpty) {
        final skippedCount = skippedDrafts.length;

        _log += 'Delta-Modus: Keine Worklogs gesendet, '
            '$skippedCount Eintrag(e) wegen Duplikat/Überlappung übersprungen.\n';

        final skippedDetails = skippedDrafts.take(25).map((d) {
          final reason = d.deltaState == DeltaState.duplicate ? 'Duplikat' : 'Überlappung';
          return '$reason: ${d.issueKey} '
              '${DateFormat('dd.MM.yyyy HH:mm').format(d.start)}–${DateFormat('HH:mm').format(d.end)} '
              '(${formatDuration(d.duration)}) '
              '${d.note}';
        }).join('\n');

        setState(() {});

        await _showInfoDialog(
          'Keine Buchungen vorgenommen',
          'Es wurden keine Worklogs an Jira gesendet, weil alle '
              'im gewählten Zeitraum bereits als Duplikat oder überlappend erkannt wurden.\n\n'
              'Übersprungene Einträge: $skippedCount\n\n'
              '${skippedDetails.isEmpty ? '' : skippedDetails}',
        );
        return;
      }

      _log += 'Delta-Modus: ${skippedDrafts.length} Eintrag(e) wegen Duplikat/Überlappung übersprungen, '
          '${draftsToSend.length} werden gesendet.\n';

      // ---------- Issues auflösen (nur für die, die wir WIRKLICH schicken) ----------
      final keys = draftsToSend.map((d) => d.issueKey).toSet().toList();
      final keyToId = <String, String>{};
      for (final k in keys) {
        final id = await jira.resolveIssueId(k);
        if (id != null) {
          _log += 'Resolved $k → $id\n';
          keyToId[k] = id;
        } else {
          _log += 'WARN: Konnte IssueId für $k nicht auflösen – buche mit Key.\n';
        }
      }

      int ok = 0, fail = 0;
      final failures = <String>[];
      final total = draftsToSend.length;

      for (int i = 0; i < draftsToSend.length; i++) {
        final d = draftsToSend[i];
        final key = _issueOverrides[_draftKey(d)] ?? d.issueKey;
        final keyOrId = keyToId[key] ?? key;
        
        // Update progress
        progressNotifier.value = (i + 1, total, '$key – ${DateFormat('dd.MM.yyyy').format(d.start)}');
        
        // Entferne Präfix für Jira (z.B. "Meeting 09:00–10:00 – " oder "Arbeit")
        String jiraComment = d.note;
        // Pattern: "Meeting HH:mm–HH:mm – Titel" oder "Meeting HH:mm–HH:mm"
        final meetingPrefixPattern = RegExp(r'^Meeting\s+\d{1,2}:\d{2}[–-]\d{1,2}:\d{2}\s*[–-]?\s*');
        if (meetingPrefixPattern.hasMatch(jiraComment)) {
          jiraComment = jiraComment.replaceFirst(meetingPrefixPattern, '').trim();
        } else if (jiraComment == 'Arbeit' || jiraComment.startsWith('Arbeit ')) {
          jiraComment = '';
        }
        
        final res = await worklogApi.createWorklog(
          issueKeyOrId: keyOrId,
          started: d.start,
          timeSpentSeconds: d.duration.inSeconds,
          comment: jiraComment,
        );
        if (res.ok) {
          ok++;
          _log += 'OK (Jira) $key '
              '${DateFormat('dd.MM.yyyy').format(d.start)} '
              '${d.duration.inMinutes}m\n';
        } else {
          fail++;
          final line = 'FEHLER $key ${DateFormat('dd.MM.yyyy HH:mm').format(d.start)}: ${res.body ?? ''}';
          failures.add(line);
          _log += '$line\n';
        }
      }

      final skippedCount = skippedDrafts.length;
      
      // Berechne Gesamtzeit der erfolgreich gebuchten Worklogs
      final totalBookedDuration = draftsToSend.fold<Duration>(
        Duration.zero,
        (sum, d) => sum + d.duration,
      );
      final totalHours = totalBookedDuration.inHours;
      final totalMinutes = totalBookedDuration.inMinutes.remainder(60);
      final totalTimeStr = '${totalHours}h ${totalMinutes.toString().padLeft(2, '0')}m';
      
      _log += '\nFertig. Erfolgreich: $ok, Fehler: $fail, '
          'Übersprungen (Duplikat/Überlappung): $skippedCount\n'
          'Gesamtzeit gebucht: $totalTimeStr\n';
      setState(() {});

      // Dialog-Text zusammensetzen
      if (fail == 0) {
        final skippedDetails = skippedDrafts.take(25).map((d) {
          final reason = d.deltaState == DeltaState.duplicate ? 'Duplikat' : 'Überlappung';
          return '$reason: ${d.issueKey} '
              '${DateFormat('dd.MM.yyyy HH:mm').format(d.start)}–${DateFormat('HH:mm').format(d.end)} '
              '(${formatDuration(d.duration)}) '
              '${d.note}';
        }).join('\n');

        final msg = StringBuffer()
          ..writeln('Erfolgreich gebuchte Worklogs: $ok')
          ..writeln('Gesamtzeit gebucht: $totalTimeStr')
          ..writeln('Fehler: $fail')
          ..writeln('Übersprungen (Duplikat/Überlappung): $skippedCount');

        if (skippedCount > 0 && skippedDetails.isNotEmpty) {
          msg
            ..writeln()
            ..writeln('Übersprungene Einträge (Auszug):')
            ..writeln(skippedDetails);
        }

        await _showInfoDialog('Buchen erfolgreich', msg.toString());
      } else {
        final details = failures.take(25).join('\n');

        final skippedDetails = skippedDrafts.take(25).map((d) {
          final reason = d.deltaState == DeltaState.duplicate ? 'Duplikat' : 'Überlappung';
          return '$reason: ${d.issueKey} '
              '${DateFormat('dd.MM.yyyy HH:mm').format(d.start)}–${DateFormat('HH:mm').format(d.end)} '
              '(${formatDuration(d.duration)}) '
              '${d.note}';
        }).join('\n');

        final msg = StringBuffer()
          ..writeln('Erfolgreich: $ok')
          ..writeln('Gesamtzeit gebucht: $totalTimeStr')
          ..writeln('Fehler: $fail')
          ..writeln('Übersprungen (Duplikat/Überlappung): ${skippedDrafts.length}')
          ..writeln()
          ..writeln('Fehlschläge (Auszug):')
          ..writeln(details);

        if (skippedDrafts.isNotEmpty && skippedDetails.isNotEmpty) {
          msg
            ..writeln()
            ..writeln('Übersprungene Einträge (Auszug):')
            ..writeln(skippedDetails);
        }

        await _showErrorDialog(
          'Buchen teilweise/fehlgeschlagen',
          msg.toString(),
        );
      }
    } catch (e, st) {
      setState(() => _log += 'EXCEPTION beim Senden: $e\n$st\n');
      if (context.mounted) Navigator.of(context).pop(); // Progress-Dialog schließen
      await _showErrorDialog('Buchen fehlgeschlagen', '$e');
    } finally {
      progressNotifier.dispose();
      if (mounted) {
        if (context.mounted) Navigator.of(context).pop(); // Progress-Dialog schließen
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _compareWithTimetac(BuildContext context) async {
    final state = context.read<AppState>();
    
    // Check if dates are selected (works for both modes)
    final selectedDates = state.effectiveSelectedDates;
    if (selectedDates.isEmpty) {
      await _showErrorDialog('Keine Tage ausgewählt', 'Bitte wähle zuerst einen Zeitraum oder einzelne Tage aus.');
      return;
    }

    if (state.jiraAccountId == null) {
      await _showErrorDialog('Jira nicht konfiguriert', 'Bitte stelle sicher, dass Jira korrekt konfiguriert ist.');
      return;
    }

    setState(() {
      _busy = true;
      _log += '\n=== Zeiten vergleichen ===\n';
      _log += state.settings.timeCheckOutlierModeOnly 
          ? 'Modus: Nur Ausreißer (Jira außerhalb Timetac-Zeiten)\n'
          : 'Modus: Vollständiger Vergleich\n';
    });

    try {
      // Logging für den ausgewählten Bereich
      final sortedDates = selectedDates.toList()..sort();
      final firstDate = sortedDates.first;
      final lastDate = sortedDates.last;
      
      setState(() => _log += state.dateSelectionRangeMode
          ? 'Zeitraum: ${DateFormat('dd.MM.yyyy').format(firstDate)} - ${DateFormat('dd.MM.yyyy').format(lastDate)}\n'
          : 'Einzeltage: ${selectedDates.length} Tage ausgewählt\n');

      setState(() => _log += 'Lade Jira Worklogs für ${selectedDates.length} Tage via JQL...\n');

      // Nutze DeleteModeService für korrekte JQL-basierte Abfrage
      final jiraApi = JiraApi(
        baseUrl: state.settings.jiraBaseUrl,
        email: state.settings.jiraEmail,
        apiToken: state.settings.jiraApiToken,
      );
      final worklogApi = JiraWorklogApi(
        baseUrl: state.settings.jiraBaseUrl,
        email: state.settings.jiraEmail,
        apiToken: state.settings.jiraApiToken,
      );
      final deleteService = DeleteModeService(
        jiraApi: jiraApi,
        worklogApi: worklogApi,
        currentUserAccountId: state.jiraAccountId!,
      );

      final allJiraWorklogs = await deleteService.fetchWorklogsForPeriod(firstDate, lastDate);

      // Debug: Zeige was geladen wurde
      int totalWorklogs = 0;
      for (final entry in allJiraWorklogs.entries) {
        totalWorklogs += entry.value.length;
      }
      setState(() => _log += 'Gefunden: $totalWorklogs Jira-Worklogs an ${allJiraWorklogs.length} Tagen\n');

      // Debug: Zeige Details pro Tag
      for (final entry in allJiraWorklogs.entries) {
        final dayLogs = entry.value;
        if (dayLogs.isNotEmpty) {
          final earliest = dayLogs.map((w) => w.started).reduce((a, b) => a.isBefore(b) ? a : b);
          final latest = dayLogs.map((w) => w.end).reduce((a, b) => a.isAfter(b) ? a : b);
          setState(() => _log += '  ${entry.key}: ${dayLogs.length} Worklogs, ${DateFormat('HH:mm').format(earliest)} - ${DateFormat('HH:mm').format(latest)}\n');
        }
      }

      setState(() => _log += 'Vergleiche Zeiten...\n');

      // Vergleich durchführen
      final comparisonService = TimeComparisonService();
      final results = comparisonService.compare(
        timetacRows: state.timetac,
        jiraWorklogs: allJiraWorklogs,
        selectedDates: selectedDates,
        outlierModeOnly: state.settings.timeCheckOutlierModeOnly,
      );

      setState(() {
        _busy = false;
        _log += 'Vergleich abgeschlossen.\n';
      });

      if (!mounted) return;
      _showComparisonDialog(results, allJiraWorklogs);

    } catch (e, st) {
      setState(() {
        _busy = false;
        _log += 'Fehler beim Vergleich: $e\n$st\n';
      });
      await _showErrorDialog('Vergleich fehlgeschlagen', '$e');
    }
  }

  void _showComparisonDialog(List<DayComparisonResult> results, Map<String, List<JiraWorklog>> jiraWorklogs) {
    final hasIssues = results.any((r) => r.hasIssues);
    final jiraOnlyDays = results.where((r) => r.jiraOnlyDay).toList();
    final timetacOnlyDays = results.where((r) => r.timetacOnlyDay).toList();
    final withDifferences = results.where((r) => r.differences.isNotEmpty).toList();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(
              hasIssues
                  ? Icons.warning_amber_rounded
                  : Icons.check_circle_outline,
              color: hasIssues ? Colors.orange : Colors.green,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                hasIssues ? 'Unstimmigkeiten gefunden' : 'Alle Zeiten stimmen überein',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!hasIssues && results.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16.0),
                    child: Text('✓ Alle verglichenen Tage stimmen zwischen Timetac und Jira überein.'),
                  ),
                
                if (results.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16.0),
                    child: Text('Keine Tage mit Buchungen im gewählten Zeitraum gefunden.'),
                  ),
                
                // Warnung: Jira hat Buchungen aber Timetac nicht
                if (jiraOnlyDays.isNotEmpty) ...[
                  const Text('⚠ Jira-Buchungen ohne Timetac-Eintrag:', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    children: jiraOnlyDays.map((r) => Chip(
                      label: Text(DateFormat('dd.MM.').format(r.date)),
                      backgroundColor: Colors.red.shade100,
                    )).toList(),
                  ),
                  const SizedBox(height: 12),
                ],
                
                // Info: Timetac hat Daten, Jira nicht (noch nicht gebucht)
                if (timetacOnlyDays.isNotEmpty) ...[
                  const Text('ℹ Noch keine Jira-Buchungen:', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    children: timetacOnlyDays.map((r) => Chip(
                      label: Text(DateFormat('dd.MM.').format(r.date)),
                      backgroundColor: Colors.blue.shade50,
                    )).toList(),
                  ),
                  const SizedBox(height: 12),
                ],

                // Zeitunterschiede anzeigen
                if (withDifferences.isNotEmpty) ...[
                  const Text('Zeitunterschiede:', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  ...withDifferences.map((dayResult) => _buildDayDifferenceCard(dayResult)),
                ],
              ],
            ),
          ),
        ),
        actions: [
          if (withDifferences.isNotEmpty)
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _showAdjustmentPreview(withDifferences, jiraWorklogs);
              },
              icon: const Icon(Icons.auto_fix_high),
              label: const Text('Anpassen (Vorschau)'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Schließen'),
          ),
        ],
      ),
    );
  }
  
  /// Zeigt Vorschau der Anpassungen und ermöglicht deren Anwendung
  Future<void> _showAdjustmentPreview(
    List<DayComparisonResult> daysWithDifferences, 
    Map<String, List<JiraWorklog>> jiraWorklogs,
  ) async {
    final state = context.read<AppState>();
    final s = state.settings;
    
    final worklogApi = JiraWorklogApi(
      baseUrl: s.jiraBaseUrl,
      email: s.jiraEmail,
      apiToken: s.jiraApiToken,
    );
    final adjustmentService = JiraAdjustmentService(worklogApi);
    
    // Generiere Anpassungspläne für alle Tage
    final allPlans = <DayAdjustmentPlan>[];
    for (final dayResult in daysWithDifferences) {
      final dayKey = DateFormat('yyyy-MM-dd').format(dayResult.date);
      final dayJira = jiraWorklogs[dayKey] ?? [];
      final dayTimetac = state.timetac.where((r) => 
        r.date.year == dayResult.date.year && 
        r.date.month == dayResult.date.month && 
        r.date.day == dayResult.date.day
      ).toList();
      
      final plan = adjustmentService.generatePlan(
        date: dayResult.date,
        timetacRows: dayTimetac,
        jiraWorklogs: dayJira,
        outlierModeOnly: s.timeCheckOutlierModeOnly,
      );
      
      if (plan.hasChanges) {
        allPlans.add(plan);
      }
    }
    
    if (allPlans.isEmpty) {
      if (!mounted) return;
      await _showInfoDialog('Keine Anpassungen', 'Es konnten keine konkreten Anpassungen generiert werden.');
      return;
    }
    
    if (!mounted) return;
    
    // Zeige Vorschau-Dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.preview, color: Colors.blue),
            SizedBox(width: 8),
            Text('Anpassungs-Vorschau'),
          ],
        ),
        content: SizedBox(
          width: 600,
          height: 400,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${allPlans.fold<int>(0, (sum, p) => sum + p.adjustments.length)} Änderungen an ${allPlans.length} Tagen:',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                ...allPlans.map((plan) => Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          DateFormat('EEEE, dd.MM.yyyy', 'de_DE').format(plan.date),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const Divider(),
                        ...plan.groupedAdjustments.entries.map((group) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(group.key, style: TextStyle(color: Colors.grey.shade700, fontSize: 12)),
                              ...group.value.map((adj) => Padding(
                                padding: const EdgeInsets.only(left: 8, top: 2),
                                child: Text(adj.description, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                              )),
                            ],
                          ),
                        )),
                      ],
                    ),
                  ),
                )),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.check),
            label: const Text('Anwenden'),
          ),
        ],
      ),
    );
    
    if (confirmed != true) return;
    
    // Anpassungen anwenden
    setState(() => _busy = true);
    
    final allResults = <String>[];
    for (final plan in allPlans) {
      final results = await adjustmentService.applyPlan(plan);
      allResults.addAll(results);
    }
    
    setState(() {
      _busy = false;
      _log += '\n=== Jira-Anpassungen ===\n';
      _log += allResults.join('\n');
      _log += '\n';
    });
    
    if (!mounted) return;
    await _showInfoDialog(
      'Anpassungen abgeschlossen',
      '${allResults.where((r) => r.startsWith('✓')).length} Änderungen erfolgreich angewendet.\n\n'
      '${allResults.where((r) => r.startsWith('✗')).length} Fehler.',
    );
  }

  Widget _buildDayDifferenceCard(DayComparisonResult dayResult) {
    // Helper für Dauer-Formatierung
    String fmtDur(Duration d) {
      final h = d.inHours;
      final m = d.inMinutes % 60;
      if (h > 0) return '${h}h ${m}m';
      return '${m}m';
    }
    
    // Prüfe ob es Pausen- oder Dauerunterschiede gibt (um Details anzuzeigen)
    final hasPauseDiff = dayResult.differences.any((d) => 
      d.type == TimeDifferenceType.pauseTime || 
      d.type == TimeDifferenceType.duration
    );
    
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              DateFormat('EEEE, dd.MM.yyyy', 'de_DE').format(dayResult.date),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const Divider(),
            ...dayResult.differences.map((diff) {
              // Outlier-Typen anders anzeigen (mit Ticket und Details)
              final isOutlier = diff.type == TimeDifferenceType.jiraBeforeWork ||
                                diff.type == TimeDifferenceType.jiraAfterWork ||
                                diff.type == TimeDifferenceType.jiraDuringBreak;
              
              if (isOutlier) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 100,
                        child: Text(diff.typeLabel, style: const TextStyle(fontWeight: FontWeight.w500)),
                      ),
                      const SizedBox(width: 8),
                      if (diff.issueKey != null) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.cyan.shade700,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(diff.issueKey!, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        diff.jiraTime != null 
                            ? '${diff.jiraTime!.hour.toString().padLeft(2, '0')}:${diff.jiraTime!.minute.toString().padLeft(2, '0')}'
                            : '',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      if (diff.details != null) ...[
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            diff.details!,
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              }
              
              // Standard-Anzeige für normale Differenzen
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4.0),
                child: Row(
                  children: [
                    SizedBox(
                      width: 100,
                      child: Text(diff.typeLabel, style: const TextStyle(fontWeight: FontWeight.w500)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Row(
                        children: [
                          Text('Timetac: ', style: TextStyle(color: Colors.grey.shade600)),
                          Text(diff.timetacValueString, style: const TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(width: 16),
                          Text('Jira: ', style: TextStyle(color: Colors.grey.shade600)),
                          Text(diff.jiraValueString, style: const TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }),
            
            // Pausen-Aufschlüsselung anzeigen wenn es Pausenunterschiede gibt
            if (hasPauseDiff && (dayResult.timetacPause > Duration.zero || dayResult.timetacPaidNonWork > Duration.zero)) ...[
              const SizedBox(height: 8),
              const Divider(),
              Text('Timetac Pausen-Aufschlüsselung:', style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.pause_circle_outline, size: 14, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text('Pause: ${fmtDur(dayResult.timetacPause)}', style: const TextStyle(fontSize: 12)),
                  const SizedBox(width: 16),
                  const Icon(Icons.schedule, size: 14, color: Colors.amber),
                  const SizedBox(width: 4),
                  Text('Bez. Nichtarbeitszeit: ${fmtDur(dayResult.timetacPaidNonWork)}', style: const TextStyle(fontSize: 12)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HoverableInsertDivider extends StatefulWidget {
  final VoidCallback onInsertWorklog;
  final VoidCallback onInsertPause;
  final VoidCallback onInsertDoctorAppointment;

  const _HoverableInsertDivider({
    required this.onInsertWorklog,
    required this.onInsertPause,
    required this.onInsertDoctorAppointment,
  });

  @override
  State<_HoverableInsertDivider> createState() => _HoverableInsertDividerState();
}

class _HoverableInsertDividerState extends State<_HoverableInsertDivider> {
  bool _hovering = false;

  void _showMenu(BuildContext context, Offset position) {
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      items: [
        PopupMenuItem(
          onTap: widget.onInsertWorklog,
          child: const Row(
            children: [
              Icon(Icons.work_outline, size: 18),
              SizedBox(width: 8),
              Text('Worklog einfügen'),
            ],
          ),
        ),
        PopupMenuItem(
          onTap: widget.onInsertPause,
          child: const Row(
            children: [
              Icon(Icons.pause_circle_outline, size: 18),
              SizedBox(width: 8),
              Text('Pause einfügen'),
            ],
          ),
        ),
        PopupMenuItem(
          onTap: widget.onInsertDoctorAppointment,
          child: const Row(
            children: [
              Icon(Icons.schedule, size: 18, color: Colors.amber),
              SizedBox(width: 8),
              Text('Bezahlte Nichtarbeitszeit einfügen'),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapUp: (details) => _showMenu(context, details.globalPosition),
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 24, // Slightly taller for easier hit
          child: Row(
            children: [
              // Indent to align with Time column
              // Status (16+8) + TicketButton (40) + TicketKey (100) + Spacing (8)
              // 24 + 40 + 100 + 8 = 172 approx.
              // Let's try 160 + 8 padding in tile
              const SizedBox(width: 166), 
              
              AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity: _hovering ? 1.0 : 0.0,
                child: Container(
                  height: 20,
                  width: 20,
                  decoration: BoxDecoration(
                    color: _hovering ? Theme.of(context).primaryColor : Colors.grey.shade400,
                    shape: BoxShape.circle,
                    boxShadow: _hovering ? [
                      BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 4, offset: const Offset(0, 2))
                    ] : null,
                  ),
                  child: const Icon(Icons.add, color: Colors.white, size: 16),
                ),
              ),
              const Expanded(child: Divider(height: 1, indent: 8, endIndent: 8)),
            ],
          ),
        ),
      ),
    );
  }
}
