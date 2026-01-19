// lib/services/jira_adjustment_service.dart
import 'package:intl/intl.dart';
import '../models/models.dart';
import 'jira_worklog_api.dart';

/// Typ einer Anpassung
enum AdjustmentType {
  moveStart,      // Startzeit des ersten Worklogs anpassen
  moveEnd,        // Endzeit des letzten Worklogs anpassen
  shortenBefore,  // Worklog vor Pause kürzen
  shortenAfter,   // Worklog nach Pause kürzen
  split,          // Worklog in zwei Teile splitten
  delete,         // Worklog löschen (komplett in Pause)
}

/// Eine einzelne Anpassung
class WorklogAdjustment {
  final AdjustmentType type;
  final JiraWorklog original;
  final DateTime? newStart;
  final Duration? newDuration;
  final JiraWorklog? splitSecondPart; // Für split: der zweite Teil
  final String? pauseLabel; // "Pause" oder "Bezahlte Nichtarbeitszeit"
  final TimeRange? pauseRange; // Der Pausenzeitraum
  
  WorklogAdjustment({
    required this.type,
    required this.original,
    this.newStart,
    this.newDuration,
    this.splitSecondPart,
    this.pauseLabel,
    this.pauseRange,
  });
  
  String get description {
    final fmt = DateFormat('HH:mm');
    final origStart = fmt.format(original.started);
    final origEnd = fmt.format(original.end);
    
    switch (type) {
      case AdjustmentType.moveStart:
        final newStartStr = newStart != null ? fmt.format(newStart!) : '?';
        return '${original.issueKey}: Start $origStart → $newStartStr';
        
      case AdjustmentType.moveEnd:
        final DateTime newEnd = newStart != null && newDuration != null 
          ? newStart!.add(newDuration!)
          : original.started.add(newDuration ?? original.timeSpent);
        final newEndStr = fmt.format(newEnd);
        return '${original.issueKey}: Ende $origEnd → $newEndStr';
        
      case AdjustmentType.shortenBefore:
        final newEndStr = pauseRange != null ? fmt.format(pauseRange!.start) : '?';
        return '${original.issueKey}: $origStart-$origEnd → $origStart-$newEndStr';
        
      case AdjustmentType.shortenAfter:
        final newStartStr = pauseRange != null ? fmt.format(pauseRange!.end) : '?';
        return '${original.issueKey}: $origStart-$origEnd → $newStartStr-$origEnd';
        
      case AdjustmentType.split:
        final p1End = pauseRange != null ? fmt.format(pauseRange!.start) : '?';
        final p2Start = pauseRange != null ? fmt.format(pauseRange!.end) : '?';
        return '${original.issueKey}: $origStart-$origEnd → $origStart-$p1End + $p2Start-$origEnd';
        
      case AdjustmentType.delete:
        return '${original.issueKey}: $origStart-$origEnd löschen';
    }
  }
}

/// Plan für alle Anpassungen eines Tages
class DayAdjustmentPlan {
  final DateTime date;
  final List<WorklogAdjustment> adjustments;
  final Duration timetacPause;
  final Duration timetacPaidNonWork;
  final Duration jiraPause;
  
  DayAdjustmentPlan({
    required this.date,
    required this.adjustments,
    this.timetacPause = Duration.zero,
    this.timetacPaidNonWork = Duration.zero,
    this.jiraPause = Duration.zero,
  });
  
  bool get hasChanges => adjustments.isNotEmpty;
  
  /// Gruppiert Anpassungen nach Typ für die Anzeige
  Map<String, List<WorklogAdjustment>> get groupedAdjustments {
    final result = <String, List<WorklogAdjustment>>{};
    
    for (final adj in adjustments) {
      String key;
      if (adj.type == AdjustmentType.moveStart) {
        key = 'Startzeit anpassen';
      } else if (adj.type == AdjustmentType.moveEnd) {
        key = 'Endzeit anpassen';
      } else if (adj.pauseLabel != null) {
        key = '${adj.pauseLabel} (${DateFormat('HH:mm').format(adj.pauseRange!.start)}-${DateFormat('HH:mm').format(adj.pauseRange!.end)})';
      } else {
        key = 'Sonstige Anpassungen';
      }
      
      result.putIfAbsent(key, () => []).add(adj);
    }
    
    return result;
  }
}

/// Service zum Generieren und Anwenden von Jira-Anpassungen
class JiraAdjustmentService {
  final JiraWorklogApi _worklogApi;
  
  JiraAdjustmentService(this._worklogApi);
  
  /// Generiert einen Anpassungsplan für einen Tag
  DayAdjustmentPlan generatePlan({
    required DateTime date,
    required List<TimetacRow> timetacRows,
    required List<JiraWorklog> jiraWorklogs,
  }) {
    final adjustments = <WorklogAdjustment>[];
    
    if (jiraWorklogs.isEmpty || timetacRows.isEmpty) {
      return DayAdjustmentPlan(date: date, adjustments: []);
    }
    
    // Sortiere Worklogs nach Startzeit
    final sortedWorklogs = jiraWorklogs.toList()
      ..sort((a, b) => a.started.compareTo(b.started));
    
    // Timetac-Daten sammeln
    DateTime? timetacStart;
    DateTime? timetacEnd;
    Duration timetacPause = Duration.zero;
    Duration timetacPaidNonWork = Duration.zero;
    final allPauses = <TimeRange>[];
    
    
    for (final row in timetacRows) {
      // Ignoriere Abwesenheiten (Urlaub, Krank, etc.) für Start/Ende-Berechnung
      final isAbsence = _isAbsence(row.description);
      
      // Start/Ende nur für Arbeitszeilen (nicht Abwesenheiten)
      if (!isAbsence) {
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
        
        // Pausen nur für Arbeitszeilen
        timetacPause += row.pauseTotal;
        allPauses.addAll(row.pauses);
        
        // Wir summieren nicht mehr global alle Absences für die End-Berechnung,
        // da das zu Fehlern führt wenn Zeilen ohne Zeitstempel dabei sind.
      }
    }
    
    if (timetacStart == null || timetacEnd == null) {
      return DayAdjustmentPlan(date: date, adjustments: []);
    }
    
    // Non-nullable Variablen nach null-check
    final DateTime ttStart = timetacStart;
    final DateTime ttEnd = timetacEnd;
    
    // Jira Start/Ende
    final jiraStart = sortedWorklogs.first.started;
    final jiraEnd = sortedWorklogs.last.end;
    
    // --- SCHRITT 1: Startzeit anpassen ---
    if (!_isSameMinute(ttStart, jiraStart)) {
      adjustments.add(WorklogAdjustment(
        type: AdjustmentType.moveStart,
        original: sortedWorklogs.first,
        newStart: ttStart,
        newDuration: sortedWorklogs.first.end.difference(ttStart),
      ));
    }
    
    // --- SCHRITT 2: Endzeit anpassen ---
    // Wir nehmen Timetac-Ende als Ziel. 
    // Falls hier "Arzt" etc. schon abgezogen ist (was bei Timetac meist der Fall ist wenn es eine separate Buchung ist),
    // dann ist ttEnd bereits das korrekte "Arbeitsende".
    
    if (!_isSameMinute(ttEnd, jiraEnd)) {
      final lastWl = sortedWorklogs.last;
      adjustments.add(WorklogAdjustment(
        type: AdjustmentType.moveEnd,
        original: lastWl,
        newStart: lastWl.started,
        newDuration: ttEnd.difference(lastWl.started),
        // Kein spezielles Label nötig, "Endzeit anpassen" reicht
      ));
    }
    
    // --- SCHRITT 3: Pausen einfügen ---
    // Reguläre Pausen
    for (final pause in allPauses) {
      _addPauseAdjustments(
        adjustments: adjustments,
        worklogs: sortedWorklogs,
        pause: pause,
        pauseLabel: 'Pause',
      );
    }
    
    // Bezahlte Nichtarbeitszeit als synthetische Pause
    // (Wenn wir keine genauen Zeiten haben, können wir sie nicht einfügen)
    // TODO: Überlegen wie wir absenceTotal zeitlich einordnen können
    
    // Berechne aktuelle Jira-Pause
    final jiraPause = _calculateJiraPause(sortedWorklogs);
    
    // Gesamte Timetac-Pause (regulär + bezahlt)
    final timetacTotalPause = timetacPause + timetacPaidNonWork;
    
    // --- SCHRITT 4: Überschüssige Pausen in Jira schließen ---
    // Wenn Jira mehr Pause hat als Timetac, müssen wir Lücken schließen
    if (jiraPause > timetacTotalPause) {
      final excessPause = jiraPause - timetacTotalPause;
      _closeExcessGaps(
        adjustments: adjustments,
        worklogs: sortedWorklogs,
        excessToClose: excessPause,
        timetacPauses: allPauses,
      );
    }
    
    // Hinweis: Schritt 5 (bezahlte Nichtarbeitszeit) ist jetzt in Schritt 2 integriert
    // durch die Berechnung von effectiveWorkEnd
    
    return DayAdjustmentPlan(
      date: date,
      adjustments: adjustments,
      timetacPause: timetacPause,
      timetacPaidNonWork: timetacPaidNonWork,
      jiraPause: jiraPause,
    );
  }
  
  /// Fügt Anpassungen für eine Pause hinzu
  void _addPauseAdjustments({
    required List<WorklogAdjustment> adjustments,
    required List<JiraWorklog> worklogs,
    required TimeRange pause,
    required String pauseLabel,
  }) {
    for (final wl in worklogs) {
      final overlap = _getOverlap(wl, pause);
      if (overlap == null) continue;
      
      // Komplett innerhalb der Pause → löschen
      if (!wl.started.isBefore(pause.start) && !wl.end.isAfter(pause.end)) {
        adjustments.add(WorklogAdjustment(
          type: AdjustmentType.delete,
          original: wl,
          pauseLabel: pauseLabel,
          pauseRange: pause,
        ));
        continue;
      }
      
      // Startet vor der Pause, endet innerhalb → kürzen (Ende = Pausenstart)
      if (wl.started.isBefore(pause.start) && wl.end.isAfter(pause.start) && !wl.end.isAfter(pause.end)) {
        adjustments.add(WorklogAdjustment(
          type: AdjustmentType.shortenBefore,
          original: wl,
          newStart: wl.started,
          newDuration: pause.start.difference(wl.started),
          pauseLabel: pauseLabel,
          pauseRange: pause,
        ));
        continue;
      }
      
      // Startet innerhalb der Pause, endet danach → kürzen (Start = Pausenende)
      if (!wl.started.isBefore(pause.start) && wl.started.isBefore(pause.end) && wl.end.isAfter(pause.end)) {
        adjustments.add(WorklogAdjustment(
          type: AdjustmentType.shortenAfter,
          original: wl,
          newStart: pause.end,
          newDuration: wl.end.difference(pause.end),
          pauseLabel: pauseLabel,
          pauseRange: pause,
        ));
        continue;
      }
      
      // Umspannt die gesamte Pause → splitten
      if (wl.started.isBefore(pause.start) && wl.end.isAfter(pause.end)) {
        // Erster Teil: von wl.start bis pause.start
        // Zweiter Teil: von pause.end bis wl.end
        adjustments.add(WorklogAdjustment(
          type: AdjustmentType.split,
          original: wl,
          newStart: wl.started,
          newDuration: pause.start.difference(wl.started),
          splitSecondPart: JiraWorklog(
            id: '${wl.id}_split',
            issueKey: wl.issueKey,
            authorAccountId: wl.authorAccountId,
            started: pause.end,
            timeSpent: wl.end.difference(pause.end),
          ),
          pauseLabel: pauseLabel,
          pauseRange: pause,
        ));
      }
    }
  }
  
  /// Wendet einen Anpassungsplan an
  Future<List<String>> applyPlan(DayAdjustmentPlan plan) async {
    final results = <String>[];
    
    for (final adj in plan.adjustments) {
      try {
        switch (adj.type) {
          case AdjustmentType.moveStart:
          case AdjustmentType.moveEnd:
          case AdjustmentType.shortenBefore:
          case AdjustmentType.shortenAfter:
            // Update existierenden Worklog
            final response = await _worklogApi.updateWorklog(
              issueKeyOrId: adj.original.issueKey,
              worklogId: adj.original.id,
              started: adj.newStart ?? adj.original.started,
              timeSpentSeconds: (adj.newDuration ?? adj.original.timeSpent).inSeconds,
            );
            if (response.ok) {
              results.add('✓ ${adj.description}');
            } else {
              results.add('✗ ${adj.description}: ${response.body ?? "Unbekannter Fehler"}');
            }
            break;
            
          case AdjustmentType.split:
            // 1. Ersten Teil updaten
            final resp1 = await _worklogApi.updateWorklog(
              issueKeyOrId: adj.original.issueKey,
              worklogId: adj.original.id,
              started: adj.newStart ?? adj.original.started,
              timeSpentSeconds: (adj.newDuration ?? adj.original.timeSpent).inSeconds,
            );
            if (!resp1.ok) {
              results.add('✗ ${adj.description} (Teil 1): ${resp1.body ?? "Fehler"}');
              break;
            }
            // 2. Zweiten Teil erstellen
            if (adj.splitSecondPart != null) {
              final resp2 = await _worklogApi.createWorklog(
                issueKeyOrId: adj.original.issueKey,
                started: adj.splitSecondPart!.started,
                timeSpentSeconds: adj.splitSecondPart!.timeSpent.inSeconds,
              );
              if (!resp2.ok) {
                results.add('✗ ${adj.description} (Teil 2): ${resp2.body ?? "Fehler"}');
                break;
              }
            }
            results.add('✓ ${adj.description}');
            break;
            
          case AdjustmentType.delete:
            final success = await _worklogApi.deleteWorklog(
              issueKeyOrId: adj.original.issueKey,
              worklogId: adj.original.id,
            );
            if (success) {
              results.add('✓ ${adj.description}');
            } else {
              results.add('✗ ${adj.description}: Löschen fehlgeschlagen');
            }
            break;
        }
      } catch (e) {
        results.add('✗ ${adj.description}: $e');
      }
    }
    
    return results;
  }
  
  /// Prüft ob zwei Zeiten auf der gleichen Minute sind
  bool _isSameMinute(DateTime a, DateTime b) {
    return a.hour == b.hour && a.minute == b.minute;
  }
  
  /// Berechnet Überlappung zwischen Worklog und Pause
  TimeRange? _getOverlap(JiraWorklog wl, TimeRange pause) {
    final DateTime overlapStart = wl.started.isAfter(pause.start) ? wl.started : pause.start;
    final DateTime overlapEnd = wl.end.isBefore(pause.end) ? wl.end : pause.end;
    
    if (overlapEnd.isAfter(overlapStart)) {
      return TimeRange(overlapStart, overlapEnd);
    }
    return null;
  }
  
  /// Berechnet Jira-Pausenzeit
  Duration _calculateJiraPause(List<JiraWorklog> worklogs) {
    if (worklogs.length < 2) return Duration.zero;
    
    Duration total = Duration.zero;
    for (int i = 1; i < worklogs.length; i++) {
      final prevEndMinutes = worklogs[i - 1].end.hour * 60 + worklogs[i - 1].end.minute;
      final currStartMinutes = worklogs[i].started.hour * 60 + worklogs[i].started.minute;
      final gap = currStartMinutes - prevEndMinutes;
      if (gap > 0) {
        total += Duration(minutes: gap);
      }
    }
    return total;
  }
  
  /// Schließt überschüssige Lücken in Jira-Worklogs
  /// Wenn Jira mehr Pause hat als Timetac, verlängern wir Worklogs um die Lücken zu füllen
  void _closeExcessGaps({
    required List<WorklogAdjustment> adjustments,
    required List<JiraWorklog> worklogs,
    required Duration excessToClose,
    required List<TimeRange> timetacPauses,
  }) {
    if (worklogs.length < 2) return;
    
    Duration remainingToClose = excessToClose;
    
    // Finde alle Lücken zwischen Worklogs
    for (int i = 0; i < worklogs.length - 1 && remainingToClose > Duration.zero; i++) {
      final currentWl = worklogs[i];
      final nextWl = worklogs[i + 1];
      
      final gapStart = currentWl.end;
      final gapEnd = nextWl.started;
      
      // Berechne Lücke in Minuten
      final gapMinutes = (gapEnd.hour * 60 + gapEnd.minute) - (gapStart.hour * 60 + gapStart.minute);
      if (gapMinutes <= 0) continue;
      
      final gapDuration = Duration(minutes: gapMinutes);
      
      // Prüfe Überlappung mit Timetac Pausen (wie viel vom Gap ist legitim?)
      Duration justifiedDuration = Duration.zero;
      
      for (final p in timetacPauses) {
          // Intersection berechnen: max(gapStart, p.start) bis min(gapEnd, p.end)
          final iStart = p.start.isAfter(gapStart) ? p.start : gapStart;
          final iEnd = p.end.isBefore(gapEnd) ? p.end : gapEnd;
          
          if (iEnd.isAfter(iStart)) {
             justifiedDuration += iEnd.difference(iStart);
          }
      }
      
      // Berechne wie viel vom Gap "zuviel" ist
      var gapExcess = gapDuration - justifiedDuration;
      if (gapExcess < Duration.zero) gapExcess = Duration.zero;
      
      // Wenn Gap komplett legitim ist (oder Timetac Pause sogar größer), nichts tun
      if (gapExcess == Duration.zero) continue;
      
      // Wir schließen maximal das, was wir noch an Gesamt-Überschuss haben
      // Und maximal das, was an diesem Gap zu viel ist
      final closeAmount = gapExcess > remainingToClose ? remainingToClose : gapExcess;
      
      if (closeAmount > Duration.zero) {
        final newEnd = gapStart.add(closeAmount);
        
        // Füge Adjustment hinzu (vorherigen Worklog verlängern)
        adjustments.add(WorklogAdjustment(
          type: AdjustmentType.moveEnd,
          original: currentWl,
          newStart: currentWl.started,
          newDuration: newEnd.difference(currentWl.started),
          pauseLabel: 'Pause kürzen (${_formatDuration(closeAmount)})',
          pauseRange: TimeRange(gapStart, newEnd),
        ));
        
        remainingToClose -= closeAmount;
      }
    }
  }
  
  String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final h = m ~/ 60;
    final min = m % 60;
    if (h > 0) return '${h}h ${min}m';
    return '${min}m';
  }
  
  /// Prüft ob eine Beschreibung eine Abwesenheit ist (Urlaub, Krank, etc.)
  bool _isAbsence(String description) {
    final lower = description.toLowerCase();
    return lower.contains('urlaub') || 
           lower.contains('krank') || 
           lower.contains('zeitausgleich') ||
           lower.contains('arzt') ||
           lower.contains('pflege') ||
           lower.contains('sonder') ||
           lower.contains('eltern') ||
           lower.contains('papamonat');
  }
}
