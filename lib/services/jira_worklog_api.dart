// lib/services/jira_worklog_api.dart
import 'dart:convert';
import 'dart:io';

class JiraWorklogResponse {
  JiraWorklogResponse({required this.ok, this.body});
  final bool ok;
  final String? body;
}

class JiraWorklog {
  JiraWorklog({
    required this.id,
    required this.issueKey,
    required this.authorAccountId,
    required this.started,
    required this.timeSpent,
  });

  final String id;
  final String issueKey;
  final String authorAccountId;
  final DateTime started;
  final Duration timeSpent;

  DateTime get end => started.add(timeSpent);
}

class JiraWorklogApi {
  JiraWorklogApi({
    required this.baseUrl,
    required this.email,
    required this.apiToken,
  });

  final String baseUrl;
  final String email;
  final String apiToken;

  String get _base => baseUrl.replaceAll(RegExp(r'/+$'), '');
  String get _auth => 'Basic ${base64Encode(utf8.encode('$email:$apiToken'))}';

  // ---- Hilfsfunktionen ----

  // ADF-Comment aus einfachem Text
  Map<String, dynamic> _adfFromText(String text) {
    final t = (text.trim().isEmpty) ? '' : text.trim();
    return {
      "type": "doc",
      "version": 1,
      "content": [
        {
          "type": "paragraph",
          "content": t.isEmpty
              ? [] // leer lassen ist ok
              : [
                  {"type": "text", "text": t}
                ]
        }
      ]
    };
  }

  // Jira-Startzeit-Format: yyyy-MM-dd'T'HH:mm:ss.SSSZ (Offset ohne Doppelpunkt)
  String _formatJiraStarted(DateTime dt) {
    final local = dt.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final mo = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final h = local.hour.toString().padLeft(2, '0');
    final mi = local.minute.toString().padLeft(2, '0');
    final s = local.second.toString().padLeft(2, '0');
    final ms = local.millisecond.toString().padLeft(3, '0');

    final off = local.timeZoneOffset;
    final sign = off.isNegative ? '-' : '+';
    final offH = off.inHours.abs().toString().padLeft(2, '0');
    final offM = (off.inMinutes.abs() % 60).toString().padLeft(2, '0');
    final offset = '$sign$offH$offM'; // <- genau so erwartet Jira

    return '$y-$mo-${d}T$h:$mi:$s.$ms$offset';
  }

  DateTime _parseJiraStarted(String value) {
    // Beispiel: 2025-11-13T08:00:00.000+0100 (Jira-Format) :contentReference[oaicite:0]{index=0}
    if (value.length >= 5) {
      final tail = value.substring(value.length - 5);
      if (RegExp(r'[+-]\d{4}$').hasMatch(tail)) {
        final withColon = '${value.substring(0, value.length - 5)}${tail.substring(0, 3)}:${tail.substring(3)}';
        return DateTime.parse(withColon);
      }
    }
    // Fallback: falls Jira irgendwann mal ein „normales“ ISO 8601 mit Doppelpunkt liefert
    return DateTime.parse(value);
  }

  Future<JiraWorklogResponse> createWorklog({
    required String issueKeyOrId,
    required DateTime started,
    required int timeSpentSeconds,
    String comment = '',
  }) async {
    final uri = Uri.parse('$_base/rest/api/3/issue/${Uri.encodeComponent(issueKeyOrId)}/worklog');

    final body = <String, dynamic>{
      "started": _formatJiraStarted(started),
      "timeSpentSeconds": timeSpentSeconds,
      "comment": _adfFromText(comment),
    };

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.authorizationHeader, _auth);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
      req.add(utf8.encode(jsonEncode(body)));

      final resp = await req.close().timeout(const Duration(seconds: 30));
      final txt = await utf8.decodeStream(resp);
      final ok = resp.statusCode >= 200 && resp.statusCode < 300;
      return JiraWorklogResponse(ok: ok, body: txt.isEmpty ? null : txt);
    } catch (e) {
      return JiraWorklogResponse(ok: false, body: '$e');
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> deleteWorklog({
    required String issueKeyOrId,
    required String worklogId,
  }) async {
    final uri = Uri.parse('$_base/rest/api/3/issue/${Uri.encodeComponent(issueKeyOrId)}/worklog/${Uri.encodeComponent(worklogId)}');

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.deleteUrl(uri);
      req.headers.set(HttpHeaders.authorizationHeader, _auth);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');

      final resp = await req.close().timeout(const Duration(seconds: 30));
      // 204 No Content ist normal bei Delete
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<List<JiraWorklog>> fetchWorklogsForIssue({
    required String issueKeyOrId,
  }) async {
    final result = <JiraWorklog>[];

    int startAt = 0;
    const maxResults = 1000;

    while (true) {
      final uri = Uri.parse(
        '$_base/rest/api/3/issue/${Uri.encodeComponent(issueKeyOrId)}/worklog'
        '?startAt=$startAt&maxResults=$maxResults',
      );

      final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);

      try {
        final req = await client.getUrl(uri);
        req.headers
          ..set(HttpHeaders.authorizationHeader, _auth)
          ..set(HttpHeaders.acceptHeader, 'application/json');

        final resp = await req.close().timeout(const Duration(seconds: 30));
        final body = await utf8.decodeStream(resp);

        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          // Bei 404 kannst du optional auf /rest/api/2/... zurückfallen
          break;
        }

        final json = jsonDecode(body) as Map;
        final worklogs = (json['worklogs'] as List?) ?? const [];
        final total = (json['total'] as num?)?.toInt() ?? worklogs.length;

        for (final wl in worklogs) {
          final m = wl as Map;

          final id = (m['id'] ?? '').toString();
          final startedRaw = (m['started'] ?? '').toString();
          final timeSpentSeconds = (m['timeSpentSeconds'] as num?)?.toInt() ?? 0;

          final author = (m['author'] as Map?) ?? const {};
          final authorAccountId = (author['accountId'] ?? '').toString();

          if (id.isEmpty || startedRaw.isEmpty || timeSpentSeconds <= 0) {
            continue;
          }

          final started = _parseJiraStarted(startedRaw);

          result.add(
            JiraWorklog(
              id: id,
              issueKey: issueKeyOrId,
              authorAccountId: authorAccountId,
              started: started,
              timeSpent: Duration(seconds: timeSpentSeconds),
            ),
          );
        }

        if (startAt + worklogs.length >= total) {
          break; // fertig paginiert
        }

        startAt += worklogs.length;
      } finally {
        // neuer Client im Loop, also hier schließen
        client.close(force: true);
      }
    }

    return result;
  }
}
