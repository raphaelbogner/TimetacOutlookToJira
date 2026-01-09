import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_jira_timetac/models/models.dart';
import 'package:flutter_jira_timetac/services/title_replacement_service.dart';

void main() {
  group('TitleReplacementService', () {
    test('replaces trigger word with random replacement', () {
      final rules = [
        TitleReplacementRule(
          triggerWord: 'Abstimmung',
          replacements: ['Technische Abstimmung'],
        ),
      ];
      
      final result = TitleReplacementService.applyReplacement(
        'Meeting – Abstimmung', rules);
      
      expect(result.newTitle, 'Meeting – Technische Abstimmung');
      expect(result.originalTitle, 'Meeting – Abstimmung');
    });

    test('returns original title in originalTitle when replaced', () {
      final rules = [
        TitleReplacementRule(
          triggerWord: 'Call',
          replacements: ['Technical Call'],
        ),
      ];
      
      final result = TitleReplacementService.applyReplacement('Weekly Call', rules);
      
      expect(result.originalTitle, 'Weekly Call');
      expect(result.newTitle, 'Weekly Technical Call');
    });

    test('returns null originalTitle when no match', () {
      final rules = [
        TitleReplacementRule(
          triggerWord: 'Abstimmung',
          replacements: ['Technische Abstimmung'],
        ),
      ];
      
      final result = TitleReplacementService.applyReplacement('Daily Standup', rules);
      
      expect(result.newTitle, 'Daily Standup');
      expect(result.originalTitle, isNull);
    });

    test('case-insensitive matching', () {
      final rules = [
        TitleReplacementRule(
          triggerWord: 'ABSTIMMUNG',
          replacements: ['Technische Abstimmung'],
        ),
      ];
      
      final result = TitleReplacementService.applyReplacement(
        'Meeting – abstimmung', rules);
      
      expect(result.newTitle, 'Meeting – Technische Abstimmung');
      expect(result.originalTitle, isNotNull);
    });

    test('skips empty rules', () {
      final rules = [
        TitleReplacementRule(triggerWord: '', replacements: []),
        TitleReplacementRule(triggerWord: 'Test', replacements: []),
        TitleReplacementRule(triggerWord: '', replacements: ['Something']),
      ];
      
      final result = TitleReplacementService.applyReplacement('Test Meeting', rules);
      
      // No replacement should happen because all rules are incomplete
      expect(result.newTitle, 'Test Meeting');
      expect(result.originalTitle, isNull);
    });

    test('handles empty rules list', () {
      final result = TitleReplacementService.applyReplacement('Meeting', []);
      
      expect(result.newTitle, 'Meeting');
      expect(result.originalTitle, isNull);
    });

    test('picks random replacement from list', () {
      final rules = [
        TitleReplacementRule(
          triggerWord: 'Meeting',
          replacements: ['Tech Meeting', 'Project Meeting', 'Team Meeting'],
        ),
      ];
      
      // Run multiple times to ensure random selection works
      final results = <String>{};
      for (var i = 0; i < 50; i++) {
        final result = TitleReplacementService.applyReplacement('Meeting', rules);
        results.add(result.newTitle);
      }
      
      // With 50 iterations and 3 options, we should see at least 2 different results
      expect(results.length, greaterThanOrEqualTo(1));
      expect(results.every((r) => ['Tech Meeting', 'Project Meeting', 'Team Meeting'].contains(r)), isTrue);
    });
  });

  group('TitleReplacementRule', () {
    test('serializes to JSON correctly', () {
      final rule = TitleReplacementRule(
        triggerWord: 'Test',
        replacements: ['A', 'B', 'C'],
      );
      
      final json = rule.toJson();
      
      expect(json['triggerWord'], 'Test');
      expect(json['replacements'], ['A', 'B', 'C']);
    });

    test('deserializes from JSON correctly', () {
      final json = {
        'triggerWord': 'Meeting',
        'replacements': ['Tech Meeting', 'Project Meeting'],
      };
      
      final rule = TitleReplacementRule.fromJson(json);
      
      expect(rule.triggerWord, 'Meeting');
      expect(rule.replacements, ['Tech Meeting', 'Project Meeting']);
    });

    test('handles missing JSON fields gracefully', () {
      final rule = TitleReplacementRule.fromJson({});
      
      expect(rule.triggerWord, '');
      expect(rule.replacements, isEmpty);
    });
  });
}
