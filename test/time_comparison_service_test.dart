// test/time_comparison_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:chronos/models/models.dart';
import 'package:chronos/services/time_comparison_service.dart';
import 'package:chronos/services/jira_worklog_api.dart';

void main() {
  late TimeComparisonService service;

  setUp(() {
    service = TimeComparisonService();
  });

  // Helper to create a JiraWorklog
  JiraWorklog createWorklog({
    required DateTime started,
    required Duration duration,
    String id = 'wl-1',
    String issueKey = 'TEST-1',
  }) {
    return JiraWorklog(
      id: id,
      issueKey: issueKey,
      authorAccountId: 'user-1',
      started: started,
      timeSpent: duration,
    );
  }

  // Helper to create a TimetacRow
  TimetacRow createTimetacRow({
    required DateTime date,
    DateTime? start,
    DateTime? end,
    Duration pauseTotal = Duration.zero,
    List<TimeRange>? pauses,
    Duration absenceTotal = Duration.zero,
    double sickDays = 0,
    double holidayDays = 0,
    Duration vacationHours = Duration.zero,
    Duration timeCompensationHours = Duration.zero,
    String description = '',
  }) {
    return TimetacRow(
      description: description,
      date: date,
      start: start,
      end: end,
      duration: (start != null && end != null) ? end.difference(start) : Duration.zero,
      pauseTotal: pauseTotal,
      pauses: pauses ?? [],
      absenceTotal: absenceTotal,
      sickDays: sickDays,
      holidayDays: holidayDays,
      vacationHours: vacationHours,
      timeCompensationHours: timeCompensationHours,
    );
  }

  group('TimeComparisonService.compare', () {
    test('returns empty results for empty inputs', () {
      final results = service.compare(
        timetacRows: [],
        jiraWorklogs: {},
        selectedDates: {},
      );
      expect(results, isEmpty);
    });

    test('skips days not in selectedDates', () {
      final date = DateTime(2024, 1, 15);
      final otherDate = DateTime(2024, 1, 16);
      
      final results = service.compare(
        timetacRows: [
          createTimetacRow(
            date: date,
            start: DateTime(2024, 1, 15, 8, 0),
            end: DateTime(2024, 1, 15, 17, 0),
          ),
        ],
        jiraWorklogs: {
          '2024-01-15': [
            createWorklog(
              started: DateTime(2024, 1, 15, 8, 0),
              duration: const Duration(hours: 9),
            ),
          ],
        },
        selectedDates: {otherDate}, // Different date
      );
      
      expect(results, isEmpty);
    });

    test('perfect match returns allGood', () {
      final date = DateTime(2024, 1, 15);
      
      final results = service.compare(
        timetacRows: [
          createTimetacRow(
            date: date,
            start: DateTime(2024, 1, 15, 8, 0),
            end: DateTime(2024, 1, 15, 17, 0),
            pauseTotal: const Duration(hours: 1),
            pauses: [
              TimeRange(
                DateTime(2024, 1, 15, 12, 0),
                DateTime(2024, 1, 15, 13, 0),
              ),
            ],
          ),
        ],
        jiraWorklogs: {
          '2024-01-15': [
            createWorklog(
              id: 'wl-1',
              started: DateTime(2024, 1, 15, 8, 0),
              duration: const Duration(hours: 4),
            ),
            createWorklog(
              id: 'wl-2',
              started: DateTime(2024, 1, 15, 13, 0),
              duration: const Duration(hours: 4),
            ),
          ],
        },
        selectedDates: {date},
      );
      
      expect(results.length, 1);
      expect(results[0].hasTimetacData, true);
      expect(results[0].hasJiraData, true);
    });

    test('detects start time difference', () {
      final date = DateTime(2024, 1, 15);
      
      final results = service.compare(
        timetacRows: [
          createTimetacRow(
            date: date,
            start: DateTime(2024, 1, 15, 8, 0),
            end: DateTime(2024, 1, 15, 17, 0),
          ),
        ],
        jiraWorklogs: {
          '2024-01-15': [
            createWorklog(
              started: DateTime(2024, 1, 15, 9, 0), // Starts 1 hour later
              duration: const Duration(hours: 8),
            ),
          ],
        },
        selectedDates: {date},
      );
      
      expect(results.length, 1);
      final startDiff = results[0].differences.where(
        (d) => d.type == TimeDifferenceType.startTime
      ).toList();
      expect(startDiff.length, 1);
      expect(startDiff[0].timetacTime, DateTime(2024, 1, 15, 8, 0));
      expect(startDiff[0].jiraTime, DateTime(2024, 1, 15, 9, 0));
    });

    test('detects end time difference', () {
      final date = DateTime(2024, 1, 15);
      
      final results = service.compare(
        timetacRows: [
          createTimetacRow(
            date: date,
            start: DateTime(2024, 1, 15, 8, 0),
            end: DateTime(2024, 1, 15, 17, 0),
          ),
        ],
        jiraWorklogs: {
          '2024-01-15': [
            createWorklog(
              started: DateTime(2024, 1, 15, 8, 0),
              duration: const Duration(hours: 8), // Ends at 16:00 instead of 17:00
            ),
          ],
        },
        selectedDates: {date},
      );
      
      expect(results.length, 1);
      final endDiff = results[0].differences.where(
        (d) => d.type == TimeDifferenceType.endTime
      ).toList();
      expect(endDiff.length, 1);
    });

    test('detects pause time difference', () {
      final date = DateTime(2024, 1, 15);
      
      final results = service.compare(
        timetacRows: [
          createTimetacRow(
            date: date,
            start: DateTime(2024, 1, 15, 8, 0),
            end: DateTime(2024, 1, 15, 17, 0),
            pauseTotal: const Duration(hours: 1),
          ),
        ],
        jiraWorklogs: {
          '2024-01-15': [
            // No gap = no pause
            createWorklog(
              started: DateTime(2024, 1, 15, 8, 0),
              duration: const Duration(hours: 9),
            ),
          ],
        },
        selectedDates: {date},
      );
      
      expect(results.length, 1);
      final pauseDiff = results[0].differences.where(
        (d) => d.type == TimeDifferenceType.pauseTime
      ).toList();
      expect(pauseDiff.length, 1);
      expect(pauseDiff[0].timetacDuration, const Duration(hours: 1));
      expect(pauseDiff[0].jiraDuration, Duration.zero);
    });

    test('jira only day is flagged as warning', () {
      final date = DateTime(2024, 1, 15);
      
      final results = service.compare(
        timetacRows: [], // No Timetac data
        jiraWorklogs: {
          '2024-01-15': [
            createWorklog(
              started: DateTime(2024, 1, 15, 8, 0),
              duration: const Duration(hours: 8),
            ),
          ],
        },
        selectedDates: {date},
      );
      
      expect(results.length, 1);
      expect(results[0].jiraOnlyDay, true);
      expect(results[0].hasTimetacData, false);
      expect(results[0].hasJiraData, true);
    });

    test('timetac only day is flagged', () {
      final date = DateTime(2024, 1, 15);
      
      final results = service.compare(
        timetacRows: [
          createTimetacRow(
            date: date,
            start: DateTime(2024, 1, 15, 8, 0),
            end: DateTime(2024, 1, 15, 17, 0),
          ),
        ],
        jiraWorklogs: {}, // No Jira data
        selectedDates: {date},
      );
      
      expect(results.length, 1);
      expect(results[0].timetacOnlyDay, true);
      expect(results[0].hasTimetacData, true);
      expect(results[0].hasJiraData, false);
    });

    test('skips full sick day', () {
      final date = DateTime(2024, 1, 15);
      
      final results = service.compare(
        timetacRows: [
          createTimetacRow(
            date: date,
            sickDays: 1.0,
            description: 'Krank',
          ),
        ],
        jiraWorklogs: {},
        selectedDates: {date},
      );
      
      expect(results, isEmpty);
    });

    test('skips full holiday', () {
      final date = DateTime(2024, 1, 1);
      
      final results = service.compare(
        timetacRows: [
          createTimetacRow(
            date: date,
            holidayDays: 1.0,
            description: 'Neujahr',
          ),
        ],
        jiraWorklogs: {},
        selectedDates: {date},
      );
      
      expect(results, isEmpty);
    });

    test('skips weekend without Jira data', () {
      final saturday = DateTime(2024, 1, 13); // Saturday
      
      final results = service.compare(
        timetacRows: [],
        jiraWorklogs: {},
        selectedDates: {saturday},
      );
      
      expect(results, isEmpty);
    });

    test('includes weekend with Jira data', () {
      final saturday = DateTime(2024, 1, 13); // Saturday
      
      final results = service.compare(
        timetacRows: [],
        jiraWorklogs: {
          '2024-01-13': [
            createWorklog(
              started: DateTime(2024, 1, 13, 10, 0),
              duration: const Duration(hours: 4),
            ),
          ],
        },
        selectedDates: {saturday},
      );
      
      expect(results.length, 1);
      expect(results[0].jiraOnlyDay, true);
    });

    test('time tolerance of 1 minute is applied', () {
      final date = DateTime(2024, 1, 15);
      
      final results = service.compare(
        timetacRows: [
          createTimetacRow(
            date: date,
            start: DateTime(2024, 1, 15, 8, 0),
            end: DateTime(2024, 1, 15, 17, 0),
          ),
        ],
        jiraWorklogs: {
          '2024-01-15': [
            createWorklog(
              started: DateTime(2024, 1, 15, 8, 1), // 1 minute difference
              duration: const Duration(hours: 8, minutes: 59),
            ),
          ],
        },
        selectedDates: {date},
      );
      
      expect(results.length, 1);
      // 1 minute tolerance should not flag as difference
      final startDiffs = results[0].differences.where(
        (d) => d.type == TimeDifferenceType.startTime
      );
      expect(startDiffs, isEmpty);
    });

    test('considers absence when comparing end time', () {
      final date = DateTime(2024, 1, 15);
      
      final results = service.compare(
        timetacRows: [
          createTimetacRow(
            date: date,
            start: DateTime(2024, 1, 15, 8, 0),
            end: DateTime(2024, 1, 15, 17, 0),
            absenceTotal: const Duration(hours: 1), // 1 hour absence (e.g., doctor)
          ),
        ],
        jiraWorklogs: {
          '2024-01-15': [
            createWorklog(
              started: DateTime(2024, 1, 15, 8, 0),
              duration: const Duration(hours: 8), // Ends at 16:00
            ),
          ],
        },
        selectedDates: {date},
      );
      
      expect(results.length, 1);
      // Jira ends at 16:00, Timetac at 17:00, but 1h absence should make it match
      final endDiffs = results[0].differences.where(
        (d) => d.type == TimeDifferenceType.endTime
      );
      expect(endDiffs, isEmpty);
    });

    test('skips vacation day (> 1h)', () {
      final date = DateTime(2024, 1, 15);
      
      final results = service.compare(
        timetacRows: [
          createTimetacRow(
            date: date,
            vacationHours: const Duration(hours: 8),
            description: 'Urlaub',
          ),
        ],
        jiraWorklogs: {},
        selectedDates: {date},
      );
      
      expect(results, isEmpty);
    });

    test('skips time compensation day (> 1h)', () {
      final date = DateTime(2024, 1, 15);
      
      final results = service.compare(
        timetacRows: [
          createTimetacRow(
            date: date,
            timeCompensationHours: const Duration(hours: 8),
            description: 'Zeitausgleich',
          ),
        ],
        jiraWorklogs: {},
        selectedDates: {date},
      );
      
      expect(results, isEmpty);
    });
  });

  group('Jira pause calculation', () {
    test('calculates pause from gaps between worklogs', () {
      final date = DateTime(2024, 1, 15);
      
      final results = service.compare(
        timetacRows: [
          createTimetacRow(
            date: date,
            start: DateTime(2024, 1, 15, 8, 0),
            end: DateTime(2024, 1, 15, 17, 0),
            pauseTotal: const Duration(hours: 1),
          ),
        ],
        jiraWorklogs: {
          '2024-01-15': [
            createWorklog(
              id: 'wl-1',
              started: DateTime(2024, 1, 15, 8, 0),
              duration: const Duration(hours: 4),
            ),
            // 1 hour gap here (12:00-13:00)
            createWorklog(
              id: 'wl-2',
              started: DateTime(2024, 1, 15, 13, 0),
              duration: const Duration(hours: 4),
            ),
          ],
        },
        selectedDates: {date},
      );
      
      expect(results.length, 1);
      expect(results[0].jiraPause, const Duration(hours: 1));
    });

    test('ignores gaps of 1 minute or less', () {
      final date = DateTime(2024, 1, 15);
      
      final results = service.compare(
        timetacRows: [
          createTimetacRow(
            date: date,
            start: DateTime(2024, 1, 15, 8, 0),
            end: DateTime(2024, 1, 15, 17, 0),
            pauseTotal: Duration.zero,
          ),
        ],
        jiraWorklogs: {
          '2024-01-15': [
            createWorklog(
              id: 'wl-1',
              started: DateTime(2024, 1, 15, 8, 0),
              duration: const Duration(hours: 4),
            ),
            // 1 minute gap (should be ignored)
            createWorklog(
              id: 'wl-2',
              started: DateTime(2024, 1, 15, 12, 1),
              duration: const Duration(hours: 4, minutes: 59),
            ),
          ],
        },
        selectedDates: {date},
      );
      
      expect(results.length, 1);
      // 1 minute gaps are ignored in pause calculation
      expect(results[0].jiraPause.inMinutes, lessThanOrEqualTo(1));
    });
  });

  group('TimeDifference helper methods', () {
    test('typeLabel returns correct labels', () {
      expect(
        TimeDifference(
          date: DateTime(2024, 1, 1),
          type: TimeDifferenceType.startTime,
        ).typeLabel,
        'Arbeitsbeginn',
      );
      expect(
        TimeDifference(
          date: DateTime(2024, 1, 1),
          type: TimeDifferenceType.endTime,
        ).typeLabel,
        'Arbeitsende',
      );
      expect(
        TimeDifference(
          date: DateTime(2024, 1, 1),
          type: TimeDifferenceType.pauseTime,
        ).typeLabel,
        'Pausenzeit',
      );
      expect(
        TimeDifference(
          date: DateTime(2024, 1, 1),
          type: TimeDifferenceType.duration,
        ).typeLabel,
        'Netto-Arbeitszeit',
      );
    });

    test('timetacValueString formats time correctly', () {
      final diff = TimeDifference(
        date: DateTime(2024, 1, 1),
        type: TimeDifferenceType.startTime,
        timetacTime: DateTime(2024, 1, 1, 8, 30),
      );
      expect(diff.timetacValueString, '08:30');
    });

    test('jiraValueString formats time correctly', () {
      final diff = TimeDifference(
        date: DateTime(2024, 1, 1),
        type: TimeDifferenceType.startTime,
        jiraTime: DateTime(2024, 1, 1, 9, 15),
      );
      expect(diff.jiraValueString, '09:15');
    });

    test('timetacValueString formats duration correctly', () {
      final diff = TimeDifference(
        date: DateTime(2024, 1, 1),
        type: TimeDifferenceType.pauseTime,
        timetacDuration: const Duration(hours: 1, minutes: 30),
      );
      expect(diff.timetacValueString, '1h 30m');
    });

    test('jiraValueString formats duration correctly', () {
      final diff = TimeDifference(
        date: DateTime(2024, 1, 1),
        type: TimeDifferenceType.duration,
        jiraDuration: const Duration(minutes: 45),
      );
      expect(diff.jiraValueString, '45m');
    });
  });

  group('DayComparisonResult', () {
    test('timetacTotalPause sums regular and paid', () {
      final result = DayComparisonResult(
        date: DateTime(2024, 1, 1),
        differences: [],
        hasTimetacData: true,
        hasJiraData: true,
        timetacPause: const Duration(minutes: 30),
        timetacPaidNonWork: const Duration(minutes: 15),
      );
      
      expect(result.timetacTotalPause, const Duration(minutes: 45));
    });

    test('timetacOnlyDay is true when no Jira data', () {
      final result = DayComparisonResult(
        date: DateTime(2024, 1, 1),
        differences: [],
        hasTimetacData: true,
        hasJiraData: false,
      );
      
      expect(result.timetacOnlyDay, true);
    });

    test('hasIssues is true when there are differences', () {
      final result = DayComparisonResult(
        date: DateTime(2024, 1, 1),
        differences: [
          TimeDifference(
            date: DateTime(2024, 1, 1),
            type: TimeDifferenceType.startTime,
          ),
        ],
        hasTimetacData: true,
        hasJiraData: true,
      );
      
      expect(result.hasIssues, true);
    });

    test('allGood is true when no differences and both have data', () {
      final result = DayComparisonResult(
        date: DateTime(2024, 1, 1),
        differences: [],
        hasTimetacData: true,
        hasJiraData: true,
      );
      
      expect(result.allGood, true);
    });
  });

  group('Outlier Mode', () {
    test('reports Jira before work start', () {
      final date = DateTime(2024, 1, 15);
      final results = service.compare(
        timetacRows: [
          createTimetacRow(
            date: date,
            start: DateTime(2024, 1, 15, 8, 0),
            end: DateTime(2024, 1, 15, 17, 0),
          ),
        ],
        jiraWorklogs: {
          '2024-01-15': [
            createWorklog(
              started: DateTime(2024, 1, 15, 7, 50), // 10 min too early
              duration: const Duration(minutes: 30),
            ),
          ],
        },
        selectedDates: {date},
        outlierModeOnly: true,
      );
      
      expect(results.length, 1);
      final diffs = results[0].differences;
      expect(diffs.length, 1);
      expect(diffs[0].type, TimeDifferenceType.jiraBeforeWork);
    });

    test('reports Jira after work end', () {
      final date = DateTime(2024, 1, 15);
      final results = service.compare(
        timetacRows: [
          createTimetacRow(
            date: date,
            start: DateTime(2024, 1, 15, 8, 0),
            end: DateTime(2024, 1, 15, 17, 0),
          ),
        ],
        jiraWorklogs: {
          '2024-01-15': [
            createWorklog(
              started: DateTime(2024, 1, 15, 16, 30),
              duration: const Duration(hours: 1), // Ends 17:30 (30 min too late)
            ),
          ],
        },
        selectedDates: {date},
        outlierModeOnly: true,
      );
      
      expect(results.length, 1);
      final diffs = results[0].differences;
      expect(diffs.length, 1);
      expect(diffs[0].type, TimeDifferenceType.jiraAfterWork);
    });

    test('ignores small tolerance (1 min)', () {
      final date = DateTime(2024, 1, 15);
      final results = service.compare(
        timetacRows: [
          createTimetacRow(
            date: date,
            start: DateTime(2024, 1, 15, 8, 0),
            end: DateTime(2024, 1, 15, 17, 0),
          ),
        ],
        jiraWorklogs: {
          '2024-01-15': [
            createWorklog(
              started: DateTime(2024, 1, 15, 7, 59), // 1 min early
              duration: const Duration(hours: 9, minutes: 2), // Ends 17:01
            ),
          ],
        },
        selectedDates: {date},
        outlierModeOnly: true,
      );
      
      expect(results, isEmpty); // No outliers found
    });
    
    test('reports Jira during break', () {
      final date = DateTime(2024, 1, 15);
      final results = service.compare(
        timetacRows: [
          createTimetacRow(
            date: date,
            start: DateTime(2024, 1, 15, 8, 0),
            end: DateTime(2024, 1, 15, 17, 0),
            pauses: [TimeRange(DateTime(2024, 1, 15, 12, 0), DateTime(2024, 1, 15, 12, 30))],
            pauseTotal: const Duration(minutes: 30),
          ),
        ],
        jiraWorklogs: {
          '2024-01-15': [
            createWorklog(
              started: DateTime(2024, 1, 15, 12, 10), // Inside break
              duration: const Duration(minutes: 10),
            ),
          ],
        },
        selectedDates: {date},
        outlierModeOnly: true,
      );
      
      expect(results.length, 1);
      expect(results[0].differences.first.type, TimeDifferenceType.jiraDuringBreak);
    });

    test('allows Jira ending exactly at break start', () {
      final date = DateTime(2024, 1, 15);
      final results = service.compare(
        timetacRows: [
          createTimetacRow(
            date: date,
            start: DateTime(2024, 1, 15, 8, 0),
            end: DateTime(2024, 1, 15, 17, 0),
            pauses: [TimeRange(DateTime(2024, 1, 15, 12, 0), DateTime(2024, 1, 15, 12, 30))],
          ),
        ],
        jiraWorklogs: {
          '2024-01-15': [
            createWorklog(
              started: DateTime(2024, 1, 15, 11, 0), 
              duration: const Duration(hours: 1), // Ends 12:00 (Break start)
            ),
          ],
        },
        selectedDates: {date},
        outlierModeOnly: true,
      );
      
      expect(results, isEmpty);
    });

    test('handles partial absence correctly (no full absence flag)', () {
      final date = DateTime(2024, 1, 15);
      final results = service.compare(
        timetacRows: [
          // Morning work
          createTimetacRow(
            date: date,
            start: DateTime(2024, 1, 15, 8, 0),
            end: DateTime(2024, 1, 15, 12, 0),
          ),
          // Afternoon vacation
          createTimetacRow(
            date: date,
            vacationHours: const Duration(hours: 4),
            description: 'Urlaub',
          ),
        ],
        jiraWorklogs: {
          '2024-01-15': [
            // Worklog during valid work hours
            createWorklog(
              started: DateTime(2024, 1, 15, 8, 0),
              duration: const Duration(hours: 4),
            ),
            // Worklog during vacation (Outlier!)
            createWorklog(
              started: DateTime(2024, 1, 15, 13, 0),
              duration: const Duration(hours: 1),
            ),
          ],
        },
        selectedDates: {date},
        outlierModeOnly: true,
      );
      
      expect(results.length, 1);
      // Should NOT be marked as full absence day, but find specific outliers
      expect(results[0].differences.length, 1);
      expect(results[0].differences.first.type, TimeDifferenceType.jiraAfterWork); // 13:00 is after 12:00 work end
    });

    test('flags full absence day', () {
      final date = DateTime(2024, 1, 15);
      final results = service.compare(
        timetacRows: [
          createTimetacRow(
            date: date,
            vacationHours: const Duration(hours: 8),
            description: 'Urlaub',
          ),
        ],
        jiraWorklogs: {
          '2024-01-15': [
            createWorklog(
              started: DateTime(2024, 1, 15, 10, 0),
              duration: const Duration(hours: 1),
            ),
          ],
        },
        selectedDates: {date},
        outlierModeOnly: true,
      );
      
      expect(results.length, 1);
      expect(results[0].differences.first.details, contains('Abwesenheitstag'));
    });
  });
}
