// lib/services/time_comparison_service.dart
import 'package:intl/intl.dart';
import '../models/models.dart';
import 'jira_worklog_api.dart';

/// Typ der Zeitdifferenz
enum TimeDifferenceType {
  startTime,   // Arbeitsbeginn
  endTime,     // Arbeitsende
  pauseTime,   // Pausenzeit
  duration,    // Netto-Arbeitszeit
}

/// Eine einzelne Zeitdifferenz an einem Tag
class TimeDifference {
  final DateTime date;
  final TimeDifferenceType type;
  final DateTime? timetacTime;     // Für Start/Ende: die Zeit
  final DateTime? jiraTime;        // Für Start/Ende: die Zeit
  final Duration? timetacDuration; // Für Pausen/Dauer: die Dauer
  final Duration? jiraDuration;    // Für Pausen/Dauer: die Dauer
  
  TimeDifference({
    required this.date,
    required this.type,
    this.timetacTime,
    this.jiraTime,
    this.timetacDuration,
    this.jiraDuration,
  });
  
  String get typeLabel {
    switch (type) {
      case TimeDifferenceType.startTime:
        return 'Arbeitsbeginn';
      case TimeDifferenceType.endTime:
        return 'Arbeitsende';
      case TimeDifferenceType.pauseTime:
        return 'Pausenzeit';
      case TimeDifferenceType.duration:
        return 'Netto-Arbeitszeit';
    }
  }
  
  String get timetacValueString {
    if (type == TimeDifferenceType.pauseTime || type == TimeDifferenceType.duration) {
      return _formatDuration(timetacDuration ?? Duration.zero);
    }
    return timetacTime != null ? DateFormat('HH:mm').format(timetacTime!) : '—';
  }
  
  String get jiraValueString {
    if (type == TimeDifferenceType.pauseTime || type == TimeDifferenceType.duration) {
      return _formatDuration(jiraDuration ?? Duration.zero);
    }
    return jiraTime != null ? DateFormat('HH:mm').format(jiraTime!) : '—';
  }
  
  static String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h > 0) {
      return '${h}h ${m}m';
    }
    return '${m}m';
  }
}

/// Ergebnis des Vergleichs für einen Tag
class DayComparisonResult {
  final DateTime date;
  final List<TimeDifference> differences;
  final bool hasTimetacData;
  final bool hasJiraData;
  final bool jiraOnlyDay; // Jira hat Daten aber Timetac nicht
  
  // Aufschlüsselung der Pausenzeiten
  final Duration timetacPause;         // Reguläre Pausen
  final Duration timetacPaidNonWork;   // Bezahlte Nichtarbeitszeit (Arzttermine etc.)
  final Duration jiraPause;            // Errechnete Jira-Pause (Lücken)
  
  DayComparisonResult({
    required this.date,
    required this.differences,
    required this.hasTimetacData,
    required this.hasJiraData,
    this.jiraOnlyDay = false,
    this.timetacPause = Duration.zero,
    this.timetacPaidNonWork = Duration.zero,
    this.jiraPause = Duration.zero,
  });
  
  /// Gesamte Timetac-Pause (regulär + bezahlt)
  Duration get timetacTotalPause => timetacPause + timetacPaidNonWork;
  
  /// Timetac hat Daten, Jira aber nicht
  bool get timetacOnlyDay => hasTimetacData && !hasJiraData;
  
  bool get hasIssues => differences.isNotEmpty || jiraOnlyDay;
  bool get allGood => differences.isEmpty && hasTimetacData && hasJiraData && !jiraOnlyDay;
}

/// Service zum Vergleichen von Timetac-Zeiten mit Jira-Worklogs
class TimeComparisonService {
  
  /// Vergleicht Timetac-Zeiten mit Jira-Worklogs für einen Zeitraum
  /// 
  /// Tage ohne Timetac-Daten werden IGNORIERT, außer Jira hat Buchungen
  /// für diesen Tag (wird als Warnung angezeigt).
  List<DayComparisonResult> compare({
    required List<TimetacRow> timetacRows,
    required Map<String, List<JiraWorklog>> jiraWorklogs,
    required Set<DateTime> selectedDates,
  }) {
    final results = <DayComparisonResult>[];
    
    // Sortiere die ausgewählten Tage
    final sortedDates = selectedDates.toList()..sort();
    
    for (final date in sortedDates) {
      final dayKey = DateFormat('yyyy-MM-dd').format(date);
      
      // Timetac-Daten für diesen Tag finden
      final dayTimetac = timetacRows.where((r) => 
        r.date.year == date.year && 
        r.date.month == date.month && 
        r.date.day == date.day
      ).toList();
      
      // Jira-Worklogs für diesen Tag  
      final dayJira = jiraWorklogs[dayKey] ?? [];
      
      // Prüfe ob es ein voller Krankenstand/Feiertag/Urlaubstag ist
      // Prüfe ob es ein voller Krankenstand/Feiertag/Urlaubstag ist
      final isFullAbsence = dayTimetac.any((r) => 
        r.sickDays > 0 || 
        r.holidayDays > 0 || 
        r.vacationHours.inMinutes > 60 || // Mehr als 1h Urlaub -> als Abwesenheitstag werten (oder prüfen ob keine Arbeitszeit da ist)
        r.timeCompensationHours.inMinutes > 60 || // Zeitausgleich > 1h
        _isAbsence(r.description)
      );
      
      // Volle Abwesenheitstage überspringen
      if (isFullAbsence) {
        continue;
      }

      // Wochenende überspringen (es sei denn Jira hat Daten, das wird unten geprüft)
      // Wir prüfen hier auf Daten, da wir im nächsten Schritt Fall 1-3 haben.
      // Wenn Wochenende und KEIN Jira -> immer überspringen, egal ob Timetac Daten hat oder nicht (User Wunsch)
      if ((date.weekday == DateTime.saturday || date.weekday == DateTime.sunday) && dayJira.isEmpty) {
        continue;
      }
      
      final hasTimetacData = dayTimetac.isNotEmpty && 
          dayTimetac.any((r) => r.start != null && r.end != null);
      final hasJiraData = dayJira.isNotEmpty;
      
      // Fall 1: Kein Timetac UND kein Jira -> Tag überspringen
      if (!hasTimetacData && !hasJiraData) {
        continue;
      }
      
      // Fall 2: Jira hat Daten aber Timetac nicht -> Warnung
      if (!hasTimetacData && hasJiraData) {
        results.add(DayComparisonResult(
          date: date,
          differences: [],
          hasTimetacData: false,
          hasJiraData: true,
          jiraOnlyDay: true,
        ));
        continue;
      }
      
      // Fall 3: Timetac hat Daten aber Jira nicht -> Info hinzufügen
      if (hasTimetacData && !hasJiraData) {
        results.add(DayComparisonResult(
          date: date,
          differences: [],
          hasTimetacData: true,
          hasJiraData: false,
        ));
        continue;
      }
      
      // Pausen-Aufschlüsselung berechnen
      Duration ttPause = Duration.zero;
      Duration ttPaidNonWork = Duration.zero;
      for (final row in dayTimetac) {
        if (!_isAbsence(row.description)) {
          ttPause += row.pauseTotal;
          ttPaidNonWork += row.absenceTotal;
        }
      }
      final jPause = _calculateJiraPauses(dayJira);
      
      // Fall 4: Beide haben Daten -> vergleichen
      final differences = <TimeDifference>[];
      differences.addAll(_compareDay(date, dayTimetac, dayJira));
      
      results.add(DayComparisonResult(
        date: date,
        differences: differences,
        hasTimetacData: hasTimetacData,
        hasJiraData: hasJiraData,
        timetacPause: ttPause,
        timetacPaidNonWork: ttPaidNonWork,
        jiraPause: jPause,
      ));
    }
    
    return results;
  }
  
  List<TimeDifference> _compareDay(
    DateTime date,
    List<TimetacRow> timetacRows,
    List<JiraWorklog> jiraWorklogs,
  ) {
    final differences = <TimeDifference>[];
    
    // Timetac: Früheste Start- und späteste Endzeit finden
    DateTime? timetacStart;
    DateTime? timetacEnd;
    Duration timetacPause = Duration.zero;
    Duration timetacAbsence = Duration.zero;
    Duration timetacNetto = Duration.zero;
    
    for (final row in timetacRows) {
      // Ignoriere Abwesenheiten (Urlaub, Krank, etc.)
      if (_isAbsence(row.description)) continue;
      
      if (row.start != null) {
        if (timetacStart == null || row.start!.isBefore(timetacStart)) {
          timetacStart = row.start;
        }
      }
      if (row.end != null) {
        if (timetacEnd == null || row.end!.isAfter(timetacEnd)) {
          timetacEnd = row.end;
        }
      }
      timetacPause += row.pauseTotal;
      timetacAbsence += row.absenceTotal;
      
      // Netto Arbeitszeit: Brutto - Pause
      // (Abwesenheit wie Arzt bleibt drin, da in Jira gebucht wird)
      timetacNetto += row.duration - row.pauseTotal;
    }
    
    // Jira: Früheste Start- und späteste Endzeit finden
    DateTime? jiraStart;
    DateTime? jiraEnd;
    Duration jiraNetto = Duration.zero;
    
    for (final wl in jiraWorklogs) {
      if (jiraStart == null || wl.started.isBefore(jiraStart)) {
        jiraStart = wl.started;
      }
      final wlEnd = wl.end;
      if (jiraEnd == null || wlEnd.isAfter(jiraEnd)) {
        jiraEnd = wlEnd;
      }
      jiraNetto += wl.timeSpent;
    }
    
    // Jira-Pausenzeit berechnen (Lücken zwischen Worklogs)
    final jiraPause = _calculateJiraPauses(jiraWorklogs);
    
    // Vergleiche Startzeit
    if (timetacStart != null && jiraStart != null) {
      if (!_isSameTime(timetacStart, jiraStart)) {
        differences.add(TimeDifference(
          date: date,
          type: TimeDifferenceType.startTime,
          timetacTime: timetacStart,
          jiraTime: jiraStart,
        ));
      }
    }
    
    // Vergleiche Endzeit
    if (timetacEnd != null && jiraEnd != null) {
      bool isEndMatch = _isSameTime(timetacEnd, jiraEnd);
      
      // Wenn Endzeit nicht passt, prüfe ob es an Abwesenheit (Arzttermin am Ende) liegt
      if (!isEndMatch && timetacAbsence > Duration.zero) {
        // Wir akzeptieren Jira-Ende, wenn es um 'absenceTotal' früher ist als Timetac-Ende
        // Bzw: JiraEnde + Absence == TimetacEnde
        if (_isSameTime(timetacEnd, jiraEnd.add(timetacAbsence))) {
          isEndMatch = true;
        }
      }
      
      if (!isEndMatch) {
        differences.add(TimeDifference(
          date: date,
          type: TimeDifferenceType.endTime,
          timetacTime: timetacEnd,
          jiraTime: jiraEnd,
        ));
      }
    }
    
    // Vergleiche Pausenzeit (NUR echte Pausen)
    if (!_isSameDuration(timetacPause, jiraPause)) {
      differences.add(TimeDifference(
        date: date,
        type: TimeDifferenceType.pauseTime,
        timetacDuration: timetacPause,
        jiraDuration: jiraPause,
      ));
    }
    
    // Vergleiche Netto-Arbeitszeit
    // Wir fügen "Ignorierte Lücken" (<= 1 Min) zu JiraNetto hinzu, 
    // da diese Lücken als "Arbeitszeit" (oder zumindest nicht als Pause) gewertet werden sollen.
    final ignoredGaps = _calculateIgnoredGaps(jiraWorklogs);
    final adjustedJiraNetto = jiraNetto + ignoredGaps;
    
    if (!_isSameDuration(timetacNetto, adjustedJiraNetto)) {
      differences.add(TimeDifference(
        date: date,
        type: TimeDifferenceType.duration,
        timetacDuration: timetacNetto,
        jiraDuration: adjustedJiraNetto,
      ));
    }
    
    return differences;
  }
  
  /// Berechnet die Pausenzeit aus Jira-Worklogs (Lücken zwischen Einträgen)
  /// Arbeitet auf Minutenebene um Rundungsfehler durch Sekunden zu vermeiden
  Duration _calculateJiraPauses(List<JiraWorklog> worklogs) {
    if (worklogs.length < 2) return Duration.zero;
    
    // Sortiere nach Startzeit
    final sorted = worklogs.toList()
      ..sort((a, b) => a.started.compareTo(b.started));
    
    Duration totalPause = Duration.zero;
    
    for (int i = 1; i < sorted.length; i++) {
      // Auf Minutenebene arbeiten (Sekunden ignorieren)
      final prevEnd = sorted[i - 1].end;
      final currStart = sorted[i].started;
      
      // Minuten extrahieren (ohne Sekunden)
      final prevEndMinutes = prevEnd.hour * 60 + prevEnd.minute;
      final currStartMinutes = currStart.hour * 60 + currStart.minute;
      
      // Wenn es eine Lücke gibt (größer als 1 Minute, um "Schein-Lücken" durch Sekunden zu ignorieren)
      final gapMinutes = currStartMinutes - prevEndMinutes;
      if (gapMinutes > 1) {
        totalPause += Duration(minutes: gapMinutes);
      }
    }
    
    return totalPause;
  }

  /// Berechnet Lücken die KEINE Pause sind (<= 1 Minute), um sie der Arbeitszeit gutzuschreiben
  Duration _calculateIgnoredGaps(List<JiraWorklog> worklogs) {
    if (worklogs.length < 2) return Duration.zero;
    
    final sorted = worklogs.toList()
      ..sort((a, b) => a.started.compareTo(b.started));
    
    Duration totalIgnored = Duration.zero;
    
    for (int i = 1; i < sorted.length; i++) {
      final prevEnd = sorted[i - 1].end;
      final currStart = sorted[i].started;
      
      final prevEndMinutes = prevEnd.hour * 60 + prevEnd.minute;
      final currStartMinutes = currStart.hour * 60 + currStart.minute;
      
      final gapMinutes = currStartMinutes - prevEndMinutes;
      // Gaps <= 1 Minute zählen (die wir oben in _calculateJiraPauses ignorieren)
      if (gapMinutes > 0 && gapMinutes <= 1) {
        totalIgnored += Duration(minutes: gapMinutes);
      }
    }
    
    return totalIgnored;
  }
  
  /// Prüft ob zwei Zeiten identisch sind (mit 1 Minute Toleranz)
  bool _isSameTime(DateTime a, DateTime b) {
    final diffMinutes = (a.hour * 60 + a.minute) - (b.hour * 60 + b.minute);
    return diffMinutes.abs() <= 1;
  }
  
  /// Prüft ob zwei Dauern identisch sind (mit 2 Minuten Toleranz)
  bool _isSameDuration(Duration a, Duration b) {
    return (a.inMinutes - b.inMinutes).abs() <= 2;
  }
  
  /// Prüft ob ein Timetac-Eintrag eine Abwesenheit ist
  bool _isAbsence(String desc) {
    final d = desc.toLowerCase();
    return d.contains('urlaub') || 
           d.contains('feiertag') || 
           d.contains('krank') || 
           d.contains('abwesen') ||
           d.contains('zeitausgleich');
  }
}
