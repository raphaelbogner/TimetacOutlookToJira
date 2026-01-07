import 'dart:convert';
import 'dart:io';

class JiraIssueLight {
  JiraIssueLight({required this.key, required this.summary});
  final String key;
  final String summary;
}

class JiraApi {
  JiraApi({required this.baseUrl, required this.email, required this.apiToken});

  final String baseUrl;
  final String email;
  final String apiToken;

  String get _base => baseUrl.replaceAll(RegExp(r'/+$'), '');
  String get _auth => 'Basic ${base64Encode(utf8.encode('$email:$apiToken'))}';

  Future<String?> resolveIssueId(String keyOrId) async {
    final base = baseUrl.replaceAll(RegExp(r'/+$'), '');
    final auth = 'Basic ${base64Encode(utf8.encode('$email:$apiToken'))}';
    final uri = Uri.parse('$base/rest/api/3/issue/${Uri.encodeComponent(keyOrId)}');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.authorizationHeader, auth);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final body = await utf8.decodeStream(resp);
        final m = jsonDecode(body) as Map<String, dynamic>;
        return (m['id'] ?? '').toString().isEmpty ? null : (m['id'] as String);
      }
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<List<JiraIssueLight>> searchIssues(String query, {int maxResults = 25}) async {
    if (baseUrl.isEmpty || email.isEmpty || apiToken.isEmpty) return const [];
    final isKeyLike = RegExp(r'^[A-Za-z][A-Za-z0-9]+-\d+$').hasMatch(query.trim());
    final jql = isKeyLike
        ? '(key = ${query.trim()}) OR (summary ~ "${query.trim()}" OR key ~ "${query.trim()}")'
        : '(summary ~ "${query.trim()}" OR key ~ "${query.trim()}")';

    final uri = Uri.parse(
      '$_base/rest/api/3/search/jql?jql=${Uri.encodeQueryComponent(jql)}&fields=summary&maxResults=$maxResults',
    );

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.authorizationHeader, _auth);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final resp = await req.close().timeout(const Duration(seconds: 20));
      final body = await utf8.decodeStream(resp);

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        // optional: Logging dem Aufrufer überlassen
        return const [];
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      final issues = (json['issues'] as List?) ?? const [];
      return issues
          .map((it) {
            final m = it as Map<String, dynamic>;
            final key = (m['key'] ?? '').toString();
            final fields = (m['fields'] as Map?) ?? const {};
            final summary = (fields['summary'] ?? '').toString();
            return JiraIssueLight(key: key, summary: summary);
          })
          .where((i) => i.key.isNotEmpty)
          .toList();
    } finally {
      client.close(force: true);
    }
  }

  /// Führt eine rohe JQL-Query aus und gibt eine Liste von Issue-Keys zurück
  Future<List<String>> searchJql(String jql, {int maxResults = 100}) async {
    if (baseUrl.isEmpty || email.isEmpty || apiToken.isEmpty) return const [];

    final uri = Uri.parse(
      '$_base/rest/api/3/search/jql?jql=${Uri.encodeQueryComponent(jql)}&fields=key&maxResults=$maxResults',
    );

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.authorizationHeader, _auth);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final resp = await req.close().timeout(const Duration(seconds: 30));
      
      if (resp.statusCode < 200 || resp.statusCode >= 300) return const [];

      final body = await utf8.decodeStream(resp);
      final json = jsonDecode(body) as Map<String, dynamic>;
      final issues = (json['issues'] as List?) ?? const [];
      
      return issues.map((it) {
        final m = it as Map<String, dynamic>;
        return (m['key'] ?? '').toString();
      }).where((k) => k.isNotEmpty).toList();
    } catch (_) {
      return const [];
    } finally {
      client.close(force: true);
    }
  }

  // Optional: Keys → Summaries (ersetzt deinen Batch in main.dart)
  Future<Map<String, String>> fetchSummariesByKeys(Set<String> keys, {int batchSize = 50}) async {
    if (baseUrl.isEmpty || email.isEmpty || apiToken.isEmpty || keys.isEmpty) return {};
    final result = <String, String>{};
    final list = keys.toList();
    for (var i = 0; i < list.length; i += batchSize) {
      final slice = list.sublist(i, (i + batchSize > list.length) ? list.length : i + batchSize);
      final jql = 'key in (${slice.map((k) => k.trim()).join(',')})';
      final uri = Uri.parse(
        '$_base/rest/api/3/search/jql?jql=${Uri.encodeQueryComponent(jql)}&fields=summary&maxResults=${slice.length}',
      );

      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      try {
        final req = await client.getUrl(uri);
        req.headers.set(HttpHeaders.authorizationHeader, _auth);
        req.headers.set(HttpHeaders.acceptHeader, 'application/json');
        final resp = await req.close().timeout(const Duration(seconds: 20));
        if (resp.statusCode < 200 || resp.statusCode >= 300) continue;
        final body = await utf8.decodeStream(resp);
        final json = jsonDecode(body) as Map<String, dynamic>;
        final issues = (json['issues'] as List?) ?? const [];
        for (final it in issues) {
          final m = it as Map<String, dynamic>;
          final key = (m['key'] ?? '').toString();
          final fields = (m['fields'] as Map?) ?? const {};
          final summary = (fields['summary'] ?? '').toString();
          if (key.isNotEmpty && summary.isNotEmpty) result[key] = summary;
        }
      } finally {
        client.close(force: true);
      }
    }
    return result;
  }
}

extension JiraAuth on JiraApi {
  Future<bool> checkAuth() async {
    if (_base.isEmpty || email.isEmpty || apiToken.isEmpty) return false;

    Future<int> ping(String path) async {
      final uri = Uri.parse('$_base$path');
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      try {
        final req = await client.getUrl(uri);
        req.headers
          ..set(HttpHeaders.authorizationHeader, _auth)
          ..set(HttpHeaders.acceptHeader, 'application/json');
        final resp = await req.close().timeout(const Duration(seconds: 20));
        // Body nicht nötig, nur Status
        return resp.statusCode;
      } catch (_) {
        return -1;
      } finally {
        client.close(force: true);
      }
    }

    final c3 = await ping('/rest/api/3/myself');
    if (c3 == 200) return true;
    if (c3 == 401 || c3 == 403) return false;

    // Fallback für Jira Server/Data Center
    final c2 = await ping('/rest/api/2/myself');
    return c2 == 200;
  }
}

extension JiraMe on JiraApi {
  Future<String?> fetchMyAccountId() async {
    if (_base.isEmpty) return null;

    final uri = Uri.parse('$_base/rest/api/3/myself');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);

    try {
      final req = await client.getUrl(uri);
      req.headers
        ..set(HttpHeaders.authorizationHeader, _auth)
        ..set(HttpHeaders.acceptHeader, 'application/json');

      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;

      final body = await utf8.decodeStream(resp);
      final json = jsonDecode(body) as Map;
      final id = (json['accountId'] ?? '').toString();
      return id.isEmpty ? null : id;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
