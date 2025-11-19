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
import 'ui/preview_utils.dart';
import 'widgets/preview_table.dart';

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
            title: 'Timetac + Outlook → Jira Worklogs',
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

    if (_gitlabFieldsFilled) {
      await validateGitlabCredentials();
    } else {
      _gitlabAuthOk = false;
      notifyListeners();
    }
  }

  Future<bool> validateJiraCredentials() async {
    if (!_jiraFieldsFilled) {
      _jiraAuthOk = false;
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
  bool get _jiraFieldsFilled =>
      settings.jiraBaseUrl.trim().isNotEmpty &&
      settings.jiraEmail.trim().isNotEmpty &&
      settings.jiraApiToken.trim().isNotEmpty &&
      settings.meetingIssueKey.trim().isNotEmpty &&
      settings.fallbackIssueKey.trim().isNotEmpty;

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

  bool get isGitlabConfigured => _gitlabFieldsFilled && _gitlabAuthOk;

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

    if (range != null) {
      final s = DateTime(range!.start.year, range!.start.month, range!.start.day);
      final e = DateTime(range!.end.year, range!.end.month, range!.end.day);
      dates.retainWhere((d) => !d.isBefore(s) && !d.isAfter(e));
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
  Map<String, String> _jiraSummaryCache = {};
  int _tabIndex = 0;

  final Map<String, String> _issueOverrides = {}; // draftKey -> newKey
  String _draftKey(DraftLog d) => '${d.start.millisecondsSinceEpoch}-${d.end.millisecondsSinceEpoch}-${d.issueKey}';

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

    if (_tabIndex == 0) {
      // Preview
      if (state.totals.isEmpty) {
        return const Padding(
          padding: EdgeInsets.all(12.0),
          child: Text('Keine Daten für die Vorschau.'),
        );
      }
      return PreviewTable(days: state.totals);
    }

    if (_tabIndex == 1) {
      // Geplante Worklogs
      if (_drafts.isEmpty) {
        return const Padding(
          padding: EdgeInsets.all(12.0),
          child: Text('Noch keine geplanten Worklogs.'),
        );
      }
      return _plannedList(context, _drafts);
    }

    // Logs
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Timetac + Outlook → Jira Worklogs'),
        actionsPadding: const EdgeInsets.only(right: 12.0),
        actions: [
          _statusPill(state.isJiraConfigured, 'Jira'),
          _statusPill(state.isTimetacConfigured, 'Timetac'),
          _statusPill(state.isGitlabConfigured, 'GitLab'),
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
        currentIndex: _tabIndex,
        onTap: (i) => setState(() => _tabIndex = i),
        items: const [
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
            child: SingleChildScrollView(
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

  // kleine Statusanzeige (Icon + Label darunter)
  Widget _statusPill(bool ok, String label) {
    final color = ok ? Colors.green : Colors.red;
    final icon = ok ? Icons.check_circle : Icons.cancel;

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

  Widget _plannedList(BuildContext context, List<DraftLog> drafts) {
    final settings = context.read<AppState>().settings;
    final jira = JiraApi(baseUrl: settings.jiraBaseUrl, email: settings.jiraEmail, apiToken: settings.jiraApiToken);
    final byDay = <String, List<DraftLog>>{};
    for (final d in drafts) {
      final key = DateFormat('dd.MM.yyyy').format(d.start);
      (byDay[key] ??= []).add(d);
    }
    final dayKeys = byDay.keys.toList()..sort();

    final meetingKey = context.read<AppState>().settings.meetingIssueKey;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Geplante Worklogs', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _deltaLegend(),
          const SizedBox(height: 16),
          for (final day in dayKeys) ...[
            Text(day, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final w in byDay[day]!)
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 2),
                child: Builder(builder: (_) {
                  final draftId = _draftKey(w);
                  final effectiveKey = _issueOverrides[draftId] ?? w.issueKey;
                  final maybeTitle = (effectiveKey != meetingKey) ? (_jiraSummaryCache[effectiveKey] ?? '') : '';
                  final line = '$effectiveKey  ${_hhmm(w.start)}–${_hhmm(w.end)}  (${formatDuration(w.duration)})  '
                      '${w.note}${maybeTitle.isNotEmpty ? ' – $maybeTitle' : ''}';

                  // Stil je nach Delta-Status
                  TextStyle style = const TextStyle(fontFamily: 'monospace');
                  switch (w.deltaState) {
                    case DeltaState.newEntry:
                      // Standard
                      break;
                    case DeltaState.duplicate:
                      style = style.copyWith(color: Colors.grey);
                      break;
                    case DeltaState.overlap:
                      style = style.copyWith(color: Colors.orange);
                      break;
                  }

                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _deltaBadge(w),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Ticket ändern',
                        icon: const Icon(Icons.swap_horiz),
                        onPressed: () async {
                          final picked = await _openIssuePickerDialog(
                            originalKey: w.issueKey,
                            currentKey: effectiveKey,
                            title: 'Ticket für ${DateFormat('dd.MM.yyyy HH:mm').format(w.start)} ändern',
                          );
                          if (picked != null && picked.isNotEmpty) {
                            setState(() {
                              _issueOverrides[draftId] = picked;
                              if (!_jiraSummaryCache.containsKey(picked)) {
                                jira.fetchSummariesByKeys({picked}).then((m) {
                                  if (m.isNotEmpty && mounted) {
                                    setState(() => _jiraSummaryCache.addAll(m));
                                  }
                                });
                              }
                            });
                          }
                        },
                      ),
                      Expanded(child: Text(line, style: style)),
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
                  : () async {
                      final picked = await showDateRangePicker(
                        context: context,
                        firstDate: minDate.subtract(const Duration(days: 365)),
                        lastDate: maxDate.add(const Duration(days: 365)),
                        initialDateRange: activeRange ?? DateTimeRange(start: minDate, end: maxDate),
                        helpText: 'Bitte Zeitraum wählen',
                        locale: const Locale('de', 'DE'),
                      );
                      if (picked != null) {
                        setState(() {
                          context.read<AppState>().range = picked;
                          _drafts = [];
                          _log += 'Zeitraum: ${picked.start} – ${picked.end}\n';
                        });
                      }
                    },
              icon: const Icon(Icons.calendar_today),
              label: Text(
                activeRange == null
                    ? 'Zeitraum wählen'
                    : '${DateFormat('dd.MM.yyyy').format(activeRange.start)} – '
                        '${DateFormat('dd.MM.yyyy').format(activeRange.end)}',
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _buildCalculateButtons(BuildContext context) {
    final state = context.watch<AppState>();
    final locked = !state.isAllConfigured;
    final canCalculate = !locked && state.hasCsv && state.hasIcs;

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
            ]),
            if (!state.hasCsv || !state.hasIcs)
              const Text(
                'CSV und ICS laden, um „Berechnen“ zu aktivieren.',
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

    await showDialog(
      context: context,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => DefaultTabController(
          length: 5,
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

              bool jiraTesting = false;
              bool gitlabTesting = false;

              Widget settingsIcon(bool ok) => Icon(
                    ok ? Icons.check_circle : Icons.cancel,
                    size: 18,
                    color: ok ? Colors.green : Colors.red,
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
                        // Titelzeile
                        Row(
                          children: [
                            const Expanded(
                              child: Text('Einstellungen', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                            ),
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
                                  settingsIcon(gitlabOk()),
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
                                                context.read<AppState>().markJiraUnknown();
                                                setDlg(() => jiraTesting = true);
                                                final ok = await context.read<AppState>().validateJiraCredentials();
                                                setDlg(() => jiraTesting = false);

                                                _showInfoDialog(
                                                  'Jira-Verbindung',
                                                  ok ? 'Jira-Verbindung erfolgreich' : 'Jira-Verbindung fehlgeschlagen',
                                                );
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
                                      sectionTitle(ctx, 'Verbindung'),
                                      Row(
                                        children: [
                                          OutlinedButton.icon(
                                            onPressed: () async {
                                              final st = context.read<AppState>().settings;
                                              st.gitlabBaseUrl = glBaseCtl.text.trim().replaceAll(RegExp(r'/+$'), '');
                                              st.gitlabToken = glTokCtl.text.trim();
                                              st.gitlabProjectIds = glProjCtl.text.trim();
                                              st.gitlabAuthorEmail = glMailCtl.text.trim();
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

                                await app.savePrefs();

                                // Validieren
                                app.markJiraUnknown();
                                app.markGitlabUnknown();
                                final jiraTestOkay = await app.validateJiraCredentials();
                                final gitlabTestOkay = await app.validateGitlabCredentials();
                                if (!ctx.mounted || !context.mounted) return;

                                if (jiraTestOkay && gitlabTestOkay) {
                                  Navigator.of(ctx).pop(); // Settings schließen
                                  ScaffoldMessenger.of(context)
                                      .showSnackBar(const SnackBar(content: Text('Gespeichert und verbunden')));
                                  return;
                                }

                                // Fehlerfall: Settings-Dialog offen lassen und Fehlgrund anzeigen
                                final msg = (!jiraTestOkay && !gitlabTestOkay)
                                    ? 'Gespeichert, aber Jira und GitLab Verbindung fehlgeschlagen.'
                                    : (!jiraTestOkay)
                                        ? 'Gespeichert, aber Jira-Verbindung fehlgeschlagen.'
                                        : 'Gespeichert, aber GitLab-Verbindung fehlgeschlagen.';
                                await _showErrorDialog('Verbindung fehlgeschlagen', msg);
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

      if (state.range != null) {
        rangeStart = DateTime(state.range!.start.year, state.range!.start.month, state.range!.start.day);
        rangeEnd = DateTime(state.range!.end.year, state.range!.end.month, state.range!.end.day);
        csvDays = csvDays.where((d) => !d.isBefore(rangeStart) && !d.isAfter(rangeEnd)).toList();
        _log +=
            'Zeitraum aktiv: ${DateFormat('dd.MM.yyyy').format(rangeStart)} – ${DateFormat('dd.MM.yyyy').format(rangeEnd)}\n';
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

      if (s.gitlabBaseUrl.isNotEmpty && s.gitlabToken.isNotEmpty && s.gitlabProjectIds.isNotEmpty) {
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
                final titleSuffix = titleText.isEmpty ? '' : ' – $titleText';
                meetingDrafts.add(
                  DraftLog(
                    start: s1,
                    end: e1,
                    issueKey: issueKeyForMeeting,
                    note: 'Meeting ${DateFormat('HH:mm').format(s1)}–${DateFormat('HH:mm').format(e1)}$titleSuffix',
                  ),
                );
              }
            }
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

        // Arztbesuch vom Rest abziehen (wie Pause), vom Tagesende rückwärts
        final trimmedRest = _trimPiecesFromEndBy(doctor, restPieces);

        // Rest auf Tickets verteilen
        final restDrafts = ordered.isEmpty
            ? <DraftLog>[]
            : _assignRestPiecesByCommits(
                pieces: trimmedRest,
                ordered: ordered,
                note: 'Arbeit',
                log: (s) => _log += s,
              );

        // Drafts des Tages zusammenführen
        final dayDrafts = <DraftLog>[
          ...meetingDrafts,
          ...restDrafts,
        ]..sort((a, b) => a.start.compareTo(b.start));

        // Ticket-Overrides anwenden, falls gesetzt
        final withOverrides = dayDrafts.map((d) {
          final id = _draftKey(d);
          final overridden = _issueOverrides[id];
          if (overridden != null && overridden.trim().isNotEmpty && overridden != d.issueKey) {
            return DraftLog(start: d.start, end: d.end, issueKey: overridden, note: d.note);
          }
          return d;
        }).toList();

        allDrafts.addAll(withOverrides);

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
      final nonMeetingKeys =
          allDrafts.where((d) => d.issueKey != state.settings.meetingIssueKey).map((d) => d.issueKey).toSet();

      final needSummaries = {...nonMeetingKeys, ...overrideKeys};
      Map<String, String> summaries = {};
      if (needSummaries.isNotEmpty) {
        summaries = await jira.fetchSummariesByKeys(needSummaries);
        _log += 'Jira Summaries geholt: ${summaries.length}/${needSummaries.length}\n';
      }
      _jiraSummaryCache = summaries;

      await state.applyDeltaModeToDrafts(allDrafts);

      // Drafts direkt übernehmen, note NICHT mit Titeln anreichern
      setState(() {
        _drafts = allDrafts;
      });

      if (allDrafts.isEmpty) {
        _log += 'Hinweis: Keine Worklogs erzeugt. Prüfe CSV/ICS, Zeitraum und Commit-Filter.\n';
      }

      _log += 'Drafts: ${allDrafts.length}\n';
    } catch (e, st) {
      _log += 'EXCEPTION in Berechnung: $e\n$st\n';
    } finally {
      setState(() {
        _tabIndex = 1;
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

      for (final d in draftsToSend) {
        final key = _issueOverrides[_draftKey(d)] ?? d.issueKey;
        final keyOrId = keyToId[key] ?? key;
        final res = await worklogApi.createWorklog(
          issueKeyOrId: keyOrId,
          started: d.start,
          timeSpentSeconds: d.duration.inSeconds,
          comment: d.note,
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
      _log += '\nFertig. Erfolgreich: $ok, Fehler: $fail, '
          'Übersprungen (Duplikat/Überlappung): $skippedCount\n';
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
      await _showErrorDialog('Buchen fehlgeschlagen', '$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }
}
