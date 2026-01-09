// lib/services/title_replacement_service.dart

import 'dart:math';
import '../models/models.dart';

/// Service für automatische Titel-Ersetzung in Meeting-Titeln (für Förderung)
class TitleReplacementService {
  static final _random = Random();

  /// Wendet Ersetzungsregeln auf einen Titel an.
  /// 
  /// Gibt ein Record zurück mit:
  /// - newTitle: Der Titel nach Ersetzung (oder original wenn keine Regel matched)
  /// - originalTitle: Original-Titel nur wenn eine Ersetzung stattfand, sonst null
  /// 
  /// Die Ersetzung erfolgt zufällig aus der Liste der möglichen Ersetzungen.
  static ({String newTitle, String? originalTitle}) applyReplacement(
    String title,
    List<TitleReplacementRule> rules,
  ) {
    if (rules.isEmpty) {
      return (newTitle: title, originalTitle: null);
    }

    final lowerTitle = title.toLowerCase();
    
    for (final rule in rules) {
      if (rule.triggerWord.isEmpty || rule.replacements.isEmpty) continue;
      
      final triggerLower = rule.triggerWord.toLowerCase();
      
      if (lowerTitle.contains(triggerLower)) {
        // Zufällige Ersetzung wählen
        final replacement = rule.replacements[_random.nextInt(rule.replacements.length)];
        
        // Case-insensitive Ersetzung durchführen
        final newTitle = title.replaceAllMapped(
          RegExp(RegExp.escape(rule.triggerWord), caseSensitive: false),
          (match) => replacement,
        );
        
        // Nur originalTitle setzen wenn sich etwas geändert hat
        if (newTitle != title) {
          return (newTitle: newTitle, originalTitle: title);
        }
      }
    }

    return (newTitle: title, originalTitle: null);
  }

  /// Standard-Ersetzungsregeln für typische Förderungs-Begriffe
  static const List<TitleReplacementRule> defaultRules = [];

  /// Typische Trigger-Wörter die oft ersetzt werden (als Vorschläge)
  static const List<String> suggestedTriggerWords = [
    'Abstimmung',
    'Meeting',
    'Besprechung',
    'Jour Fixe',
    'Call',
    'Sync',
  ];

  /// Typische Ersetzungs-Beispiele für häufige Trigger-Wörter
  static const Map<String, List<String>> suggestedReplacements = {
    'Abstimmung': [
      'Technische Abstimmung',
      'Technische Analyse',
      'Fachliche Abstimmung',
      'Konzeptabstimmung',
    ],
    'Meeting': [
      'Technisches Meeting',
      'Projektmeeting',
      'Arbeitsmeeting',
    ],
    'Besprechung': [
      'Technische Besprechung',
      'Projektbesprechung',
      'Fachliche Besprechung',
    ],
  };
}
