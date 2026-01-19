// test/jira_adjustment_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:chronos/models/models.dart';
import 'package:chronos/services/jira_adjustment_service.dart';
import 'package:chronos/services/jira_worklog_api.dart';

// Mock implementation of JiraWorklogApi for testing
class MockJiraWorklogApi extends JiraWorklogApi {
  MockJiraWorklogApi() : super(
    baseUrl: 'https://mock.jira.com',
    email: 'test@example.com',
    apiToken: 'mock-token',
  );

  final List<Map<String, dynamic>> calls = [];
  bool shouldFail = false;

  @override
  Future<JiraWorklogResponse> updateWorklog({
    required String issueKeyOrId,
    required String worklogId,
    required DateTime started,
    required int timeSpentSeconds,
    String? comment,
  }) async {
    calls.add({
      'action': 'update',
      'issueKey': issueKeyOrId,
      'worklogId': worklogId,
      'started': started,
      'timeSpentSeconds': timeSpentSeconds,
    });
    return JiraWorklogResponse(ok: !shouldFail);
  }

  @override
  Future<JiraWorklogResponse> createWorklog({
    required String issueKeyOrId,
    required DateTime started,
    required int timeSpentSeconds,
    String comment = '',
  }) async {
    calls.add({
      'action': 'create',
      'issueKey': issueKeyOrId,
      'started': started,
      'timeSpentSeconds': timeSpentSeconds,
    });
    return JiraWorklogResponse(ok: !shouldFail);
  }

  @override
  Future<bool> deleteWorklog({
    required String issueKeyOrId,
    required String worklogId,
  }) async {
    calls.add({
      'action': 'delete',
      'issueKey': issueKeyOrId,
      'worklogId': worklogId,
    });
    return !shouldFail;
  }
}

void main() {
  late MockJiraWorklogApi mockApi;
  late JiraAdjustmentService service;

  setUp(() {
    mockApi = MockJiraWorklogApi();
    service = JiraAdjustmentService(mockApi);
  });

  // Helper to create a JiraWorklog
  JiraWorklog createWorklog({
    required String id,
    required DateTime started,
    required Duration duration,
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
    required DateTime start,
    required DateTime end,
    Duration pauseTotal = Duration.zero,
    List<TimeRange>? pauses,
    Duration absenceTotal = Duration.zero,
  }) {
    return TimetacRow(
      description: '',
      date: date,
      start: start,
      end: end,
      duration: end.difference(start),
      pauseTotal: pauseTotal,
      pauses: pauses ?? [],
      absenceTotal: absenceTotal,
    );
  }

  group('JiraAdjustmentService.generatePlan', () {
    test('returns empty plan for empty worklogs', () {
      final plan = service.generatePlan(
        date: DateTime(2024, 1, 15),
        timetacRows: [
          createTimetacRow(
            date: DateTime(2024, 1, 15),
            start: DateTime(2024, 1, 15, 8, 0),
            end: DateTime(2024, 1, 15, 17, 0),
          ),
        ],
        jiraWorklogs: [],
      );

      expect(plan.hasChanges, false);
      expect(plan.adjustments, isEmpty);
    });

    test('returns empty plan for empty timetac rows', () {
      final plan = service.generatePlan(
        date: DateTime(2024, 1, 15),
        timetacRows: [],
        jiraWorklogs: [
          createWorklog(
            id: 'wl-1',
            started: DateTime(2024, 1, 15, 8, 0),
            duration: const Duration(hours: 8),
          ),
        ],
      );

      expect(plan.hasChanges, false);
    });

    test('adjusts start time when Jira starts later', () {
      final plan = service.generatePlan(
        date: DateTime(2024, 1, 15),
        timetacRows: [
          createTimetacRow(
            date: DateTime(2024, 1, 15),
            start: DateTime(2024, 1, 15, 8, 0),
            end: DateTime(2024, 1, 15, 17, 0),
          ),
        ],
        jiraWorklogs: [
          createWorklog(
            id: 'wl-1',
            started: DateTime(2024, 1, 15, 9, 0), // 1 hour later
            duration: const Duration(hours: 8),
          ),
        ],
      );

      expect(plan.hasChanges, true);
      final moveStart = plan.adjustments.where((a) => a.type == AdjustmentType.moveStart).toList();
      expect(moveStart.length, 1);
      expect(moveStart[0].newStart, DateTime(2024, 1, 15, 8, 0));
    });

    test('adjusts start time when Jira starts earlier', () {
      final plan = service.generatePlan(
        date: DateTime(2024, 1, 15),
        timetacRows: [
          createTimetacRow(
            date: DateTime(2024, 1, 15),
            start: DateTime(2024, 1, 15, 9, 0),
            end: DateTime(2024, 1, 15, 17, 0),
          ),
        ],
        jiraWorklogs: [
          createWorklog(
            id: 'wl-1',
            started: DateTime(2024, 1, 15, 8, 0), // 1 hour earlier
            duration: const Duration(hours: 9),
          ),
        ],
      );

      expect(plan.hasChanges, true);
      final moveStart = plan.adjustments.where((a) => a.type == AdjustmentType.moveStart).toList();
      expect(moveStart.length, 1);
      expect(moveStart[0].newStart, DateTime(2024, 1, 15, 9, 0));
    });

    test('adjusts end time when Jira ends earlier', () {
      final plan = service.generatePlan(
        date: DateTime(2024, 1, 15),
        timetacRows: [
          createTimetacRow(
            date: DateTime(2024, 1, 15),
            start: DateTime(2024, 1, 15, 8, 0),
            end: DateTime(2024, 1, 15, 17, 0),
          ),
        ],
        jiraWorklogs: [
          createWorklog(
            id: 'wl-1',
            started: DateTime(2024, 1, 15, 8, 0),
            duration: const Duration(hours: 7), // Ends at 15:00
          ),
        ],
      );

      expect(plan.hasChanges, true);
      final moveEnd = plan.adjustments.where((a) => a.type == AdjustmentType.moveEnd).toList();
      expect(moveEnd.length, 1);
      // New duration should extend to 17:00
      expect(moveEnd[0].newDuration, const Duration(hours: 9));
    });

    test('no adjustment when times match within same minute', () {
      final plan = service.generatePlan(
        date: DateTime(2024, 1, 15),
        timetacRows: [
          createTimetacRow(
            date: DateTime(2024, 1, 15),
            start: DateTime(2024, 1, 15, 8, 0),
            end: DateTime(2024, 1, 15, 17, 0),
          ),
        ],
        jiraWorklogs: [
          createWorklog(
            id: 'wl-1',
            started: DateTime(2024, 1, 15, 8, 0, 30), // Same minute
            duration: const Duration(hours: 9),
          ),
        ],
      );

      final moveStart = plan.adjustments.where((a) => a.type == AdjustmentType.moveStart).toList();
      expect(moveStart, isEmpty);
    });

    test('splits worklog when pause is inside', () {
      final plan = service.generatePlan(
        date: DateTime(2024, 1, 15),
        timetacRows: [
          createTimetacRow(
            date: DateTime(2024, 1, 15),
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
        jiraWorklogs: [
          createWorklog(
            id: 'wl-1',
            started: DateTime(2024, 1, 15, 8, 0),
            duration: const Duration(hours: 9), // Spans entire day including pause
          ),
        ],
      );

      final splits = plan.adjustments.where((a) => a.type == AdjustmentType.split).toList();
      expect(splits.length, 1);
      expect(splits[0].pauseLabel, 'Pause');
      expect(splits[0].pauseRange?.start, DateTime(2024, 1, 15, 12, 0));
      expect(splits[0].pauseRange?.end, DateTime(2024, 1, 15, 13, 0));
      expect(splits[0].splitSecondPart, isNotNull);
      expect(splits[0].splitSecondPart!.started, DateTime(2024, 1, 15, 13, 0));
    });

    test('shortens worklog before pause', () {
      final plan = service.generatePlan(
        date: DateTime(2024, 1, 15),
        timetacRows: [
          createTimetacRow(
            date: DateTime(2024, 1, 15),
            start: DateTime(2024, 1, 15, 8, 0),
            end: DateTime(2024, 1, 15, 17, 0),
            pauseTotal: const Duration(hours: 1),
            pauses: [
              TimeRange(
                DateTime(2024, 1, 15, 11, 0),
                DateTime(2024, 1, 15, 12, 0),
              ),
            ],
          ),
        ],
        jiraWorklogs: [
          createWorklog(
            id: 'wl-1',
            started: DateTime(2024, 1, 15, 8, 0),
            duration: const Duration(hours: 3, minutes: 30), // Ends at 11:30 (in pause)
          ),
          createWorklog(
            id: 'wl-2',
            started: DateTime(2024, 1, 15, 12, 0),
            duration: const Duration(hours: 5),
          ),
        ],
      );

      final shortenBefore = plan.adjustments.where((a) => a.type == AdjustmentType.shortenBefore).toList();
      expect(shortenBefore.length, 1);
      // Should be shortened to end at 11:00 (pause start)
      expect(shortenBefore[0].newDuration, const Duration(hours: 3));
    });

    test('shortens worklog after pause', () {
      final plan = service.generatePlan(
        date: DateTime(2024, 1, 15),
        timetacRows: [
          createTimetacRow(
            date: DateTime(2024, 1, 15),
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
        jiraWorklogs: [
          createWorklog(
            id: 'wl-1',
            started: DateTime(2024, 1, 15, 8, 0),
            duration: const Duration(hours: 4),
          ),
          createWorklog(
            id: 'wl-2',
            started: DateTime(2024, 1, 15, 12, 30), // Starts in pause
            duration: const Duration(hours: 4, minutes: 30),
          ),
        ],
      );

      final shortenAfter = plan.adjustments.where((a) => a.type == AdjustmentType.shortenAfter).toList();
      expect(shortenAfter.length, 1);
      // Should start at 13:00 (pause end)
      expect(shortenAfter[0].newStart, DateTime(2024, 1, 15, 13, 0));
    });

    test('deletes worklog completely inside pause', () {
      final plan = service.generatePlan(
        date: DateTime(2024, 1, 15),
        timetacRows: [
          createTimetacRow(
            date: DateTime(2024, 1, 15),
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
        jiraWorklogs: [
          createWorklog(
            id: 'wl-1',
            started: DateTime(2024, 1, 15, 8, 0),
            duration: const Duration(hours: 4),
          ),
          createWorklog(
            id: 'wl-short',
            started: DateTime(2024, 1, 15, 12, 15), // Completely in pause
            duration: const Duration(minutes: 30),
          ),
          createWorklog(
            id: 'wl-2',
            started: DateTime(2024, 1, 15, 13, 0),
            duration: const Duration(hours: 4),
          ),
        ],
      );

      final deletes = plan.adjustments.where((a) => a.type == AdjustmentType.delete).toList();
      expect(deletes.length, 1);
      expect(deletes[0].original.id, 'wl-short');
    });

    test('ignores absence for end time calculation (trusts Timetac end)', () {
      final plan = service.generatePlan(
        date: DateTime(2024, 1, 15),
        timetacRows: [
          createTimetacRow(
            date: DateTime(2024, 1, 15),
            start: DateTime(2024, 1, 15, 8, 0),
            end: DateTime(2024, 1, 15, 17, 0),
            absenceTotal: const Duration(hours: 1), // e.g., doctor appointment
          ),
        ],
        jiraWorklogs: [
          createWorklog(
            id: 'wl-1',
            started: DateTime(2024, 1, 15, 8, 0),
            duration: const Duration(hours: 9), // Ends 17:00
          ),
        ],
      );

      // Should NOT move end, because Timetac says end is 17:00.
      // We don't blindly subtract absence anymore.
      expect(plan.hasChanges, false);
    });

    test('targets timetac end directly even with absence (no double subtraction)', () {
      // Scenario: User works until 12:39, then has Doctor appointment (2h).
      // Timetac reports end at 12:39 (net work end).
      // Jira is booked until 15:00.
      // We should cut Jira to 12:39, NOT (12:39 - 2h).
      final plan = service.generatePlan(
        date: DateTime(2024, 1, 15),
        timetacRows: [
          createTimetacRow(
            date: DateTime(2024, 1, 15),
            start: DateTime(2024, 1, 15, 8, 00),
            end: DateTime(2024, 1, 15, 12, 39),
            absenceTotal: const Duration(hours: 2, minutes: 5),
          ),
        ],
        jiraWorklogs: [
          createWorklog(
            id: 'wl-1',
            started: DateTime(2024, 1, 15, 8, 00),
            duration: const Duration(hours: 7), // Ends 15:00
          ),
        ],
      );

      expect(plan.hasChanges, true);
      final moveEnd = plan.adjustments.where((a) => a.type == AdjustmentType.moveEnd).toList();
      expect(moveEnd.length, 1);
      
      // New duration should reflect end at 12:39
      // 12:39 - 08:00 = 4h 39m
      final expectedDuration = DateTime(2024, 1, 15, 12, 39).difference(DateTime(2024, 1, 15, 8, 0));
      expect(moveEnd[0].newDuration, expectedDuration);
    });

    test('handles multiple pauses in a day', () {
      final plan = service.generatePlan(
        date: DateTime(2024, 1, 15),
        timetacRows: [
          createTimetacRow(
            date: DateTime(2024, 1, 15),
            start: DateTime(2024, 1, 15, 8, 0),
            end: DateTime(2024, 1, 15, 17, 0),
            pauseTotal: const Duration(hours: 1, minutes: 15),
            pauses: [
              TimeRange(
                DateTime(2024, 1, 15, 10, 0),
                DateTime(2024, 1, 15, 10, 15),
              ),
              TimeRange(
                DateTime(2024, 1, 15, 12, 0),
                DateTime(2024, 1, 15, 13, 0),
              ),
            ],
          ),
        ],
        jiraWorklogs: [
          createWorklog(
            id: 'wl-1',
            started: DateTime(2024, 1, 15, 8, 0),
            duration: const Duration(hours: 9), // 8:00 - 17:00, no breaks
          ),
        ],
      );

      // Should have split adjustments for both pauses
      expect(plan.hasChanges, true);
      final splits = plan.adjustments.where((a) => a.type == AdjustmentType.split).toList();
      expect(splits.length, 2);
    });
  });

  group('WorklogAdjustment.description', () {
    test('moveStart description format', () {
      final adj = WorklogAdjustment(
        type: AdjustmentType.moveStart,
        original: createWorklog(
          id: 'wl-1',
          started: DateTime(2024, 1, 15, 9, 0),
          duration: const Duration(hours: 8),
          issueKey: 'PROJ-123',
        ),
        newStart: DateTime(2024, 1, 15, 8, 0),
        newDuration: const Duration(hours: 9),
      );

      expect(adj.description, contains('PROJ-123'));
      expect(adj.description, contains('Start'));
      expect(adj.description, contains('09:00'));
      expect(adj.description, contains('08:00'));
    });

    test('moveEnd description format', () {
      final adj = WorklogAdjustment(
        type: AdjustmentType.moveEnd,
        original: createWorklog(
          id: 'wl-1',
          started: DateTime(2024, 1, 15, 8, 0),
          duration: const Duration(hours: 8),
          issueKey: 'PROJ-123',
        ),
        newStart: DateTime(2024, 1, 15, 8, 0),
        newDuration: const Duration(hours: 9),
      );

      expect(adj.description, contains('PROJ-123'));
      expect(adj.description, contains('Ende'));
    });

    test('split description format', () {
      final adj = WorklogAdjustment(
        type: AdjustmentType.split,
        original: createWorklog(
          id: 'wl-1',
          started: DateTime(2024, 1, 15, 8, 0),
          duration: const Duration(hours: 9),
          issueKey: 'PROJ-123',
        ),
        pauseRange: TimeRange(
          DateTime(2024, 1, 15, 12, 0),
          DateTime(2024, 1, 15, 13, 0),
        ),
      );

      expect(adj.description, contains('PROJ-123'));
      expect(adj.description, contains('08:00'));
      expect(adj.description, contains('12:00'));
      expect(adj.description, contains('13:00'));
    });

    test('delete description format', () {
      final adj = WorklogAdjustment(
        type: AdjustmentType.delete,
        original: createWorklog(
          id: 'wl-1',
          started: DateTime(2024, 1, 15, 12, 15),
          duration: const Duration(minutes: 30),
          issueKey: 'PROJ-123',
        ),
      );

      expect(adj.description, contains('PROJ-123'));
      expect(adj.description, contains('löschen'));
    });
  });

  group('DayAdjustmentPlan', () {
    test('hasChanges returns false for empty adjustments', () {
      final plan = DayAdjustmentPlan(
        date: DateTime(2024, 1, 15),
        adjustments: [],
      );
      expect(plan.hasChanges, false);
    });

    test('hasChanges returns true when adjustments exist', () {
      final plan = DayAdjustmentPlan(
        date: DateTime(2024, 1, 15),
        adjustments: [
          WorklogAdjustment(
            type: AdjustmentType.moveStart,
            original: createWorklog(
              id: 'wl-1',
              started: DateTime(2024, 1, 15, 9, 0),
              duration: const Duration(hours: 8),
            ),
          ),
        ],
      );
      expect(plan.hasChanges, true);
    });

    test('groupedAdjustments groups by type correctly', () {
      final plan = DayAdjustmentPlan(
        date: DateTime(2024, 1, 15),
        adjustments: [
          WorklogAdjustment(
            type: AdjustmentType.moveStart,
            original: createWorklog(
              id: 'wl-1',
              started: DateTime(2024, 1, 15, 9, 0),
              duration: const Duration(hours: 8),
            ),
          ),
          WorklogAdjustment(
            type: AdjustmentType.moveEnd,
            original: createWorklog(
              id: 'wl-2',
              started: DateTime(2024, 1, 15, 8, 0),
              duration: const Duration(hours: 7),
            ),
          ),
        ],
      );

      final grouped = plan.groupedAdjustments;
      expect(grouped.containsKey('Startzeit anpassen'), true);
      expect(grouped.containsKey('Endzeit anpassen'), true);
    });
  });

  group('JiraAdjustmentService.applyPlan', () {
    test('applies moveStart adjustment', () async {
      final plan = DayAdjustmentPlan(
        date: DateTime(2024, 1, 15),
        adjustments: [
          WorklogAdjustment(
            type: AdjustmentType.moveStart,
            original: createWorklog(
              id: 'wl-1',
              started: DateTime(2024, 1, 15, 9, 0),
              duration: const Duration(hours: 8),
              issueKey: 'TEST-1',
            ),
            newStart: DateTime(2024, 1, 15, 8, 0),
            newDuration: const Duration(hours: 9),
          ),
        ],
      );

      final results = await service.applyPlan(plan);

      expect(results.length, 1);
      expect(results[0], startsWith('✓'));
      expect(mockApi.calls.length, 1);
      expect(mockApi.calls[0]['action'], 'update');
      expect(mockApi.calls[0]['started'], DateTime(2024, 1, 15, 8, 0));
      expect(mockApi.calls[0]['timeSpentSeconds'], const Duration(hours: 9).inSeconds);
    });

    test('applies split adjustment (two API calls)', () async {
      final plan = DayAdjustmentPlan(
        date: DateTime(2024, 1, 15),
        adjustments: [
          WorklogAdjustment(
            type: AdjustmentType.split,
            original: createWorklog(
              id: 'wl-1',
              started: DateTime(2024, 1, 15, 8, 0),
              duration: const Duration(hours: 9),
              issueKey: 'TEST-1',
            ),
            newStart: DateTime(2024, 1, 15, 8, 0),
            newDuration: const Duration(hours: 4),
            splitSecondPart: JiraWorklog(
              id: 'wl-1_split',
              issueKey: 'TEST-1',
              authorAccountId: 'user-1',
              started: DateTime(2024, 1, 15, 13, 0),
              timeSpent: const Duration(hours: 4),
            ),
          ),
        ],
      );

      final results = await service.applyPlan(plan);

      expect(results.length, 1);
      expect(results[0], startsWith('✓'));
      expect(mockApi.calls.length, 2);
      expect(mockApi.calls[0]['action'], 'update');
      expect(mockApi.calls[1]['action'], 'create');
    });

    test('applies delete adjustment', () async {
      final plan = DayAdjustmentPlan(
        date: DateTime(2024, 1, 15),
        adjustments: [
          WorklogAdjustment(
            type: AdjustmentType.delete,
            original: createWorklog(
              id: 'wl-1',
              started: DateTime(2024, 1, 15, 12, 15),
              duration: const Duration(minutes: 30),
              issueKey: 'TEST-1',
            ),
          ),
        ],
      );

      final results = await service.applyPlan(plan);

      expect(results.length, 1);
      expect(results[0], startsWith('✓'));
      expect(mockApi.calls.length, 1);
      expect(mockApi.calls[0]['action'], 'delete');
      expect(mockApi.calls[0]['worklogId'], 'wl-1');
    });

    test('handles API failure gracefully', () async {
      mockApi.shouldFail = true;

      final plan = DayAdjustmentPlan(
        date: DateTime(2024, 1, 15),
        adjustments: [
          WorklogAdjustment(
            type: AdjustmentType.moveStart,
            original: createWorklog(
              id: 'wl-1',
              started: DateTime(2024, 1, 15, 9, 0),
              duration: const Duration(hours: 8),
            ),
            newStart: DateTime(2024, 1, 15, 8, 0),
            newDuration: const Duration(hours: 9),
          ),
        ],
      );

      final results = await service.applyPlan(plan);

      expect(results.length, 1);
      expect(results[0], startsWith('✗'));
    });
  });
}
