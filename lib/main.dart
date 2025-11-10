// lib/main.dart
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models/models.dart';
import 'services/csv_parser.dart';
import 'services/ics_parser.dart';
import 'services/jira_api.dart';
import 'services/jira_worklog_api.dart';
import 'services/gitlab_api.dart';
import 'widgets/preview_table.dart';
import 'logic/worklog_builder.dart';
import 'ui/preview_utils.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState()..loadPrefs(),
      child: MaterialApp(
        title: 'Timetac + Outlook → Jira Worklogs',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
          useMaterial3: true,
        ),
        home: const HomePage(),
      ),
    );
  }
}

class AppState extends ChangeNotifier {
  SettingsModel settings = SettingsModel();
  List<TimetacRow> timetac = [];
  List<IcsEvent> icsEvents = [];

  bool get hasCsv => timetac.isNotEmpty;
  bool get hasIcs => icsEvents.isNotEmpty;

  // GitLab Cache
  List<GitlabCommit> gitlabCommits = [];

  DateTimeRange? range;

  Future<void> loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    final jsonStr = p.getString('settings');
    if (jsonStr != null) {
      try {
        settings = SettingsModel.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
      } catch (_) {}
    }
    setNonMeetingHints(settings.nonMeetingHintsList);
    notifyListeners();
  }

  Future<void> savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('settings', jsonEncode(settings.toJson()));
    setNonMeetingHints(settings.nonMeetingHintsList);
    notifyListeners();
  }

  // ---------- Konfig-Validierung ----------
  bool get isJiraConfigured =>
      settings.jiraBaseUrl.trim().isNotEmpty &&
      settings.jiraEmail.trim().isNotEmpty &&
      settings.jiraApiToken.trim().isNotEmpty;

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

  bool get isGitlabConfigured =>
      settings.gitlabBaseUrl.trim().isNotEmpty &&
      settings.gitlabToken.trim().isNotEmpty &&
      settings.gitlabProjectIds.trim().isNotEmpty;

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
  final _form = GlobalKey<FormState>();
  bool _busy = false;
  String _log = '';
  List<DraftLog> _drafts = [];
  Map<String, String> _jiraSummaryCache = {};
  int _tabIndex = 0;

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

  // ---------------- Jira Summaries holen (Batch) ----------------
  Future<Map<String, String>> _fetchJiraSummaries(Set<String> keys) async {
    final s = context.read<AppState>().settings;
    if (s.jiraBaseUrl.isEmpty || s.jiraEmail.isEmpty || s.jiraApiToken.isEmpty) return {};

    final base = s.jiraBaseUrl.replaceAll(RegExp(r'/+$'), '');
    final auth = base64Encode(utf8.encode('${s.jiraEmail}:${s.jiraApiToken}'));
    final result = <String, String>{};

    // In Batches (Jira: sinnvolle Grenze ~50)
    const batchSize = 50;
    final list = keys.toList();
    for (var i = 0; i < list.length; i += batchSize) {
      final slice = list.sublist(i, (i + batchSize > list.length) ? list.length : i + batchSize);
      // neue JQL-Route (CHANGE-2046)
      final jql = 'key in (${slice.map((k) => k.trim()).join(',')})';
      final uri = Uri.parse(
          '$base/rest/api/3/search/jql?jql=${Uri.encodeQueryComponent(jql)}&fields=summary&maxResults=${slice.length}');

      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      try {
        final req = await client.getUrl(uri);
        req.headers.set(HttpHeaders.authorizationHeader, 'Basic $auth');
        req.headers.set(HttpHeaders.acceptHeader, 'application/json');
        final resp = await req.close().timeout(const Duration(seconds: 20));
        final body = await utf8.decodeStream(resp);
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          final json = jsonDecode(body) as Map<String, dynamic>;
          final issues = (json['issues'] as List?) ?? const [];
          for (final it in issues) {
            final m = it as Map<String, dynamic>;
            final key = (m['key'] ?? '').toString();
            final fields = (m['fields'] as Map?) ?? const {};
            final summary = (fields['summary'] ?? '').toString();
            if (key.isNotEmpty && summary.isNotEmpty) {
              result[key] = summary;
            }
          }
        } else {
          _log += 'WARN Jira search ${resp.statusCode}: $body\n';
        }
      } catch (e) {
        _log += 'WARN Jira search exception: $e\n';
      } finally {
        client.close(force: true);
      }
    }

    return result;
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
    final canCalculate = !locked && state.hasCsv && state.hasIcs;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Timetac + Outlook → Jira Worklogs'),
        actions: [
          _statusPill(state.isJiraConfigured, 'Jira'),
          _statusPill(state.isTimetacConfigured, 'Timetac'),
          _statusPill(state.isGitlabConfigured, 'GitLab'),
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
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 12, children: [
                _buildInputs(context),
                _buildImportButtons(context),
                _buildRangePicker(context),
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
                  const Text('CSV und ICS laden, um „Berechnen“ zu aktivieren.',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                _switchedSection(context),
              ]),
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
    final byDay = <String, List<DraftLog>>{};
    for (final d in drafts) {
      final key = DateFormat('yyyy-MM-dd').format(d.start);
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
          for (final day in dayKeys) ...[
            Text(day, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final w in byDay[day]!)
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 2),
                child: Builder(builder: (_) {
                  final maybeTitle = (w.issueKey != meetingKey) ? (_jiraSummaryCache[w.issueKey] ?? '') : '';
                  final line = '${w.issueKey}  ${_hhmm(w.start)}–${_hhmm(w.end)}  (${formatDuration(w.duration)})  '
                      '${w.note}${maybeTitle.isNotEmpty ? ' – $maybeTitle' : ''}';
                  return Text(line, style: const TextStyle(fontFamily: 'monospace'));
                }),
              ),
            const Divider(),
          ],
        ]),
      ),
    );
  }

  Widget _buildInputs(BuildContext context) {
    final s = context.read<AppState>().settings;
    final meetingController = TextEditingController(text: s.meetingIssueKey);
    final fallbackController = TextEditingController(text: s.fallbackIssueKey);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Form(
          key: _form,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Ticket-Zuordnung', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextFormField(
                  controller: meetingController,
                  decoration: const InputDecoration(labelText: 'Jira Ticket (Meetings, z. B. ABC-123)'),
                  onChanged: (v) => s.meetingIssueKey = v.trim(),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Pflichtfeld' : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: fallbackController,
                  decoration: const InputDecoration(labelText: 'Jira Ticket (Fallback, z. B. ABC-999)'),
                  onChanged: (v) => s.fallbackIssueKey = v.trim(),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Pflichtfeld' : null,
                ),
              ),
            ]),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: () async {
                if (_form.currentState!.validate()) {
                  await context.read<AppState>().savePrefs();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Gespeichert.')));
                  }
                }
              },
              child: const Text('Speichern'),
            ),
          ]),
        ),
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

    await showDialog(
      context: context,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => DefaultTabController(
          length: 4,
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
                            Tab(
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                              settingsIcon(jiraOk()),
                              const SizedBox(width: 6),
                              const Text('Jira'),
                            ])),
                            Tab(
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                              settingsIcon(timetacOk()),
                              const SizedBox(width: 6),
                              const Text('Timetac'),
                            ])),
                            Tab(
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                              settingsIcon(gitlabOk()),
                              const SizedBox(width: 6),
                              const Text('GitLab'),
                            ])),
                            const Tab(
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Text('Non-Meeting Keywords'),
                            ])),
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
                                // ------- JIRA -------
                                SingleChildScrollView(
                                  child: Column(
                                    spacing: 8,
                                    children: [
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
                                          label: const Text('Gitlab-Übersicht der Projekte öffnen'),
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
                                  ),
                                ),

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
                                )
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
                                final st = context.read<AppState>().settings;

                                // Jira
                                st.jiraBaseUrl = baseCtl.text.trim().replaceAll(RegExp(r'/+$'), '');
                                st.jiraEmail = mailCtl.text.trim();
                                st.jiraApiToken = jiraTokCtl.text.trim();

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

                                // --- Non-Meeting-Hints speichern ---
                                // 1) aktive Defaults
                                final effectiveDefaults =
                                    defaultsNonMeeting.where((d) => activeDefaults.contains(d)).toList();

                                // 2) valide Custom-Zeilen
                                final customList = customHintCtrls
                                    .map((c) => c.text.trim().toLowerCase())
                                    .where((e) => e.isNotEmpty)
                                    .toList();

                                // 3) zusammenführen, Reihenfolge: Defaults dann Custom
                                st.nonMeetingHintsMultiline = [
                                  ...effectiveDefaults,
                                  ...customList,
                                ].join('\n');

                                await context.read<AppState>().savePrefs();
                                if (context.mounted) Navigator.pop(ctx);
                              },
                              child: const Text('Speichern'),
                            ),
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
    setState(() {
      _busy = true;
      _log += 'Berechne…\n';
      _drafts = [];
    });

    try {
      clearIcsDayCache(); // defensiv

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
            'Zeitraum aktiv: ${DateFormat('yyyy-MM-dd').format(rangeStart)} – ${DateFormat('yyyy-MM-dd').format(rangeEnd)}\n';
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

      // ⚡ Meetings für den Zeitraum vorbereiten (Fast-Cache)
      prepareUserMeetingsRange(
        allEvents: state.icsEvents,
        userEmail: state.settings.jiraEmail,
        from: rangeStart,
        to: rangeEnd,
      );

      // GitLab
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

        final workWindows = state.workWindowsForDay(day);
        final productiveDur = workWindows.fold<Duration>(Duration.zero, (p, w) => p + w.duration);

        final rowsForDay = state.timetac
            .where((r) => r.date.year == day.year && r.date.month == day.month && r.date.day == day.day)
            .toList();
        final ignoreOutlook = productiveDur == Duration.zero ||
            rowsForDay.any((r) {
              final d = r.description.toLowerCase();
              return d.contains('urlaub') || d.contains('feiertag') || d.contains('krank') || d.contains('abwesen');
            });

        final meetingCutters = <WorkWindow>[];
        final meetingDrafts = <DraftLog>[];
        if (!ignoreOutlook) {
          final events = meetingsForUserOnDayFast(day: day, userEmail: state.settings.jiraEmail);
          for (final e in events) {
            meetingCutters.add(WorkWindow(e.start, e.end));
            for (final w in workWindows) {
              final s1 = e.start.isAfter(w.start) ? e.start : w.start;
              final e1 = e.end.isBefore(w.end) ? e.end : w.end;
              if (e1.isAfter(s1)) {
                final title = (e.summary.trim().isEmpty) ? '' : ' – ${e.summary.trim()}';
                meetingDrafts.add(DraftLog(
                  start: s1,
                  end: e1,
                  issueKey: state.settings.meetingIssueKey,
                  note: 'Meeting ${DateFormat('HH:mm').format(s1)}–${DateFormat('HH:mm').format(e1)}$title',
                ));
              }
            }
          }
        }

        // Arzttermine nur berücksichtigen, wenn KT/FT/UT = 0
        final ktDays = rowsForDay.fold<double>(0.0, (p, r) => p + r.sickDays);
        final ftDays = rowsForDay.fold<double>(0.0, (p, r) => p + r.holidayDays);
        final utDays = rowsForDay.fold<Duration>(Duration.zero, (p, r) => p + r.vacationHours);
        final doctor = (ktDays == 0.0 && ftDays == 0.0 && utDays == Duration.zero)
            ? rowsForDay.fold<Duration>(Duration.zero, (p, r) => p + r.absenceTotal)
            : Duration.zero;

        // Rest = Arbeitsfenster minus Meetings
        final restPieces = <WorkWindow>[];
        for (final w in workWindows) {
          restPieces.addAll(subtractIntervals(w, meetingCutters));
        }

        // Arzttermin vom Rest abziehen
        final trimmedRest = _trimPiecesFromEndBy(doctor, restPieces);

        final restDrafts = ordered.isEmpty
            ? <DraftLog>[]
            : _assignRestPiecesByCommits(
                pieces: trimmedRest,
                ordered: ordered,
                note: 'Arbeit',
                log: (s) => _log += s,
              );

        final dayDrafts = <DraftLog>[
          ...meetingDrafts,
          ...restDrafts,
        ]..sort((a, b) => a.start.compareTo(b.start));

        allDrafts.addAll(dayDrafts);

        final meetingDur = meetingDrafts.fold<Duration>(Duration.zero, (p, d) => p + d.duration);
        final dayTicketCount =
            ordered.where((c) => c.at.year == day.year && c.at.month == day.month && c.at.day == day.day).length;

        _log += 'Tag ${DateFormat('yyyy-MM-dd').format(day)}: '
            'Timetac=${formatDuration(productiveDur)}, '
            'Meetings=${formatDuration(meetingDur)}, '
            '${ignoreOutlook ? 'Outlook ignoriert' : 'Outlook berücksichtigt'}, '
            '${ordered.isNotEmpty ? 'GitLab aktiv ($dayTicketCount/${ordered.length})' : 'GitLab aus'}\n';
      }

      // -------- Jira Summaries anhängen (nur Arbeits-Logs) --------
      final nonMeetingKeys =
          allDrafts.where((d) => d.issueKey != state.settings.meetingIssueKey).map((d) => d.issueKey).toSet();

      Map<String, String> summaries = {};
      if (nonMeetingKeys.isNotEmpty) {
        summaries = await _fetchJiraSummaries(nonMeetingKeys);
        _log += 'Jira Summaries geholt: ${summaries.length}/${nonMeetingKeys.length}\n';
      }

      _jiraSummaryCache = summaries;

      final enrichedDrafts = <DraftLog>[];
      for (final d in allDrafts) {
        if (d.issueKey != state.settings.meetingIssueKey) {
          final title = summaries[d.issueKey];
          if (title != null && title.trim().isNotEmpty) {
            enrichedDrafts.add(DraftLog(
              start: d.start,
              end: d.end,
              issueKey: d.issueKey,
              note: '${d.note} – $title',
            ));
            continue;
          }
        }
        enrichedDrafts.add(d);
      }

      setState(() {
        _drafts = enrichedDrafts;
      });

      if (enrichedDrafts.isEmpty) {
        _log += 'Hinweis: Keine Worklogs erzeugt. Prüfe CSV/ICS, Zeitraum und Commit-Filter.\n';
      }

      _log += 'Drafts: ${enrichedDrafts.length}\n';
    } catch (e, st) {
      _log += 'EXCEPTION in Berechnung: $e\n$st\n';
    } finally {
      setState(() {
        _busy = false;
        _tabIndex = 1;
      });
    }
  }

  Future<void> _bookToJira(BuildContext context) async {
    final state = context.read<AppState>();
    if (_drafts.isEmpty) {
      setState(() => _log += 'Keine Worklogs zu senden.\n');
      return;
    }
    if (!state.isJiraConfigured) {
      setState(() => _log += 'FEHLER: Jira-Zugangsdaten fehlen.\n');
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

      final keys = _drafts.map((d) => d.issueKey).toSet().toList();
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
      for (final d in _drafts) {
        final keyOrId = keyToId[d.issueKey] ?? d.issueKey;
        final res = await worklogApi.createWorklog(
          issueKeyOrId: keyOrId,
          started: d.start,
          timeSpentSeconds: d.duration.inSeconds,
          comment: d.note,
        );
        if (res.ok) {
          ok++;
          _log += 'OK (Jira) ${d.issueKey} ${DateFormat('yyyy-MM-dd').format(d.start)} ${d.duration.inMinutes}m\n';
        } else {
          fail++;
          _log += 'FEHLER (Jira) ${d.issueKey} ${DateFormat('yyyy-MM-dd').format(d.start)}: ${res.body ?? ''}\n';
        }
      }

      _log += '\nFertig. Erfolgreich: $ok, Fehler: $fail\n';
      setState(() {});
    } catch (e, st) {
      setState(() => _log += 'EXCEPTION beim Senden: $e\n$st\n');
    } finally {
      setState(() {
        _busy = false;
      });
    }
  }
}
