// lib/services/gitlab_api.dart  🆕 NEU: GitLab API + Commit-Modell
import 'dart:convert';
import 'package:http/http.dart' as http;

class GitlabCommit {
  GitlabCommit({
    required this.projectId,
    required this.id,
    required this.createdAt,
    required this.message,
    this.authorEmail,
    this.authorName,
    this.committerEmail,
    this.committerName,
  });

  final String projectId;
  final String id;
  final DateTime createdAt; // lokal konvertiert
  final String message;

  final String? authorEmail;
  final String? authorName;
  final String? committerEmail;
  final String? committerName;

  @override
  String toString() {
    return 'projectId: $projectId - id: $id - createdAt: $createdAt - message: $message - authorEmail: $authorEmail - authorName: $authorName - committerEmail: $committerEmail - committerName: $committerName';
  }
}

class GitlabApi {
  GitlabApi({required this.baseUrl, required this.token});
  final String baseUrl;
  final String token;

  Map<String, String> get _headers => {
        'PRIVATE-TOKEN': token,
        'Accept': 'application/json',
      };

  /// Holt Commits eines Projekts innerhalb [since, until).
  /// Wenn [authorEmail] gesetzt ist, nutzt den Server-Filter (spart Bandbreite).
  Future<List<GitlabCommit>> fetchCommits({
    required String projectId,
    required DateTime since,
    required DateTime until,
    String? authorEmail,
    int perPage = 100,
    int maxPages = 50,
  }) async {
    final out = <GitlabCommit>[];
    var page = 1;

    while (page <= maxPages) {
      final qp = <String, String>{
        'since': since.toUtc().toIso8601String(),
        'until': until.toUtc().toIso8601String(),
        'per_page': perPage.toString(),
        'page': page.toString(),
        'all': 'true',
      };
      if (authorEmail != null && authorEmail.trim().isNotEmpty) {
        qp['author_email'] = authorEmail.trim();
      }

      final uri = Uri.parse(
        '$baseUrl/api/v4/projects/${Uri.encodeComponent(projectId)}/repository/commits',
      ).replace(queryParameters: qp);

      final res = await http.get(uri, headers: _headers);
      if (res.statusCode != 200) break;

      final list = jsonDecode(res.body) as List<dynamic>;
      if (list.isEmpty) break;

      for (final it in list) {
        final m = it as Map<String, dynamic>;
        final msg = (m['message'] ?? '').toString();
        // bevorzugt committed_date → sonst created_at → sonst authored_date
        final tsRaw = (m['committed_date'] ?? m['created_at'] ?? m['authored_date'] ?? '').toString();
        if (tsRaw.isEmpty) continue;

        DateTime created;
        try {
          created = DateTime.parse(tsRaw).toLocal();
        } catch (_) {
          continue;
        }

        out.add(GitlabCommit(
          projectId: projectId,
          id: (m['id'] ?? '').toString(),
          createdAt: created,
          message: msg,
          authorEmail:
              (m['author_email'] ?? '').toString().trim().isEmpty ? null : (m['author_email'] as String).trim(),
          authorName: (m['author_name'] ?? '').toString().trim().isEmpty ? null : (m['author_name'] as String).trim(),
          committerEmail:
              (m['committer_email'] ?? '').toString().trim().isEmpty ? null : (m['committer_email'] as String).trim(),
          committerName:
              (m['committer_name'] ?? '').toString().trim().isEmpty ? null : (m['committer_name'] as String).trim(),
        ));
      }

      // NEU ✅ – case-insensitive, Link-Header-Fallback, und Fallback auf perPage
      String? nextPage = res.headers.entries
          .firstWhere((e) => e.key.toLowerCase() == 'x-next-page', orElse: () => const MapEntry('', ''))
          .value;
      if (nextPage.isEmpty) {
        // Link-Header z. B.: <...page=3>; rel="next", <...page=5>; rel="last"
        final link = res.headers.entries
            .firstWhere((e) => e.key.toLowerCase() == 'link', orElse: () => const MapEntry('', ''))
            .value;
        if (link.isNotEmpty) {
          final m = RegExp(r'<[^>]*[?&]page=(\d+)[^>]*>;\s*rel="next"').firstMatch(link);
          if (m != null) nextPage = m.group(1);
        }
      }
      // Wenn wir weder X-Next-Page noch Link finden, aber weniger als perPage Datensätze bekamen → Ende
      if (nextPage == null || nextPage.isEmpty) {
        if (list.length < perPage) break;
        // sonst zur Sicherheit dennoch inkrementieren (manche Instanzen senden keine Header)
        page += 1;
      } else {
        page = int.tryParse(nextPage) ?? (page + 1);
      }
    }

    return out;
  }
}

extension GitlabAuth on GitlabApi {
  String get _base => baseUrl.replaceAll(RegExp(r'/+$'), '');

  Future<bool> checkAuth() async {
    if (_base.isEmpty || token.trim().isEmpty) return false;

    // 1) Primär: /user
    try {
      final u = Uri.parse('$_base/api/v4/user');
      final r = await http.get(u, headers: _headers).timeout(const Duration(seconds: 10));
      if (r.statusCode == 200) return true;
      if (r.statusCode == 401 || r.statusCode == 403) return false;
    } catch (_) {
      // weiter zu Fallback
    }

    // 2) Fallback: minimaler Projekte-Call
    try {
      final u =
          Uri.parse('$_base/api/v4/projects').replace(queryParameters: const {'per_page': '1', 'membership': 'true'});
      final r = await http.get(u, headers: _headers).timeout(const Duration(seconds: 10));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
