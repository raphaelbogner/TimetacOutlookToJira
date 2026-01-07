import 'package:intl/intl.dart';
import 'jira_api.dart';
import 'jira_worklog_api.dart';

class DeleteModeService {
  DeleteModeService({
    required this.jiraApi,
    required this.worklogApi,
    required this.currentUserAccountId,
  });

  final JiraApi jiraApi;
  final JiraWorklogApi worklogApi;
  final String currentUserAccountId;

  /// Holt alle Worklogs des eingeloggten Users in einem gewissen Zeitraum.
  /// Gibt eine Map zurück: Datum (yyyy-MM-dd) -> Liste von JiraWorklog
  Future<Map<String, List<JiraWorklog>>> fetchWorklogsForPeriod(DateTime start, DateTime end) async {
    // 1. Issues finden, wo ich Worklogs habe im Zeitraum
    // JQL: worklogAuthor = currentUser() AND worklogDate >= "yyyy-mm-dd" AND worklogDate <= "yyyy-mm-dd"
    final sStr = DateFormat('yyyy-MM-dd').format(start);
    final eStr = DateFormat('yyyy-MM-dd').format(end);

    final jql = 'worklogAuthor = "$currentUserAccountId" AND worklogDate >= "$sStr" AND worklogDate <= "$eStr"';
    
    // Wir holen Issues. Leider gibt Jira API keine direkte "Get all worklogs for user" API, 
    // man muss über die Issues gehen. Das kann teuer sein bei vielen Issues.
    final issueKeys = await jiraApi.searchJql(jql, maxResults: 200);

    final result = <String, List<JiraWorklog>>{};

    // 2. Für jedes Issue Worklogs laden und filtern
    for (final key in issueKeys) {
      try {
        final logs = await worklogApi.fetchWorklogsForIssue(issueKeyOrId: key);
        for (final w in logs) {
          // Filter: User muss übereinstimmen
          if (w.authorAccountId != currentUserAccountId) continue;
          
          // Filter: Datum muss im Zeitraum liegen (ignorieren wir Zeitzonen-Feinheiten, nehmen wir Local vom Start)
          // JiraWorklogData ist DateTime (UTC je nach Parser, aber wir haben es local geparsed)
          final d = w.started; 
          // Check range strict?
          // Wir nehmen Tag genau:
          if (d.isBefore(start) && !_isSameDay(d, start)) continue;
          if (d.isAfter(end) && !_isSameDay(d, end)) continue;

          final dateKey = DateFormat('yyyy-MM-dd').format(d);
          result.putIfAbsent(dateKey, () => []).add(w);
        }
      } catch (_) {
        // Fail silent for single issue
      }
    }

    return result;
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }
}
