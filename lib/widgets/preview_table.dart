// lib/widgets/preview_table.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../ui/preview_utils.dart';
import '../main.dart';

class PreviewTable extends StatelessWidget {
  const PreviewTable({super.key, required this.days});
  final List<DayTotals> days;

  @override
  Widget build(BuildContext context) {
    // Heuristik: wenn settings.csvColDuration numerisch ist, als Stunden/Tag verwenden, sonst 8.5
    final hoursPerDaySetting = context.read<AppState>().settings.csvColDuration.trim();
    final hoursPerDay = double.tryParse(hoursPerDaySetting.isEmpty ? '' : hoursPerDaySetting) ?? 8.5;

    String fmt(Duration d) => formatDuration(d);
    Duration daysToDuration(double days) => Duration(minutes: (days * hoursPerDay * 60).round());

    bool hasAnyAbsence(DayTotals d) =>
        d.sickDays > 0 ||
        d.holidayDays > 0 ||
        d.vacationHours > Duration.zero ||
        d.doctorHours > Duration.zero ||
        d.timeCompensationHours > Duration.zero;

    String absenceLabel(DayTotals d) {
      final parts = <String>[];

      if (d.sickDays > 0) {
        parts.add('Krankenstand (${fmt(daysToDuration(d.sickDays))})');
      }
      if (d.holidayDays > 0) {
        parts.add('Feiertag (${fmt(daysToDuration(d.holidayDays))})');
      }
      if (d.vacationHours > Duration.zero) {
        parts.add('Urlaub (${fmt(d.vacationHours)})');
      }
      if (d.timeCompensationHours > Duration.zero) {
        parts.add('Zeitausgleich (${fmt(d.timeCompensationHours)})');
      }
      if (d.doctorHours > Duration.zero) {
        parts.add('Arzttermin (${fmt(d.doctorHours)})');
      }

      return parts.isEmpty ? '-' : parts.join(' | ');
    }

    // Leertage (0h und ohne Abwesenheit) ausblenden
    final visible = days.where((d) {
      final zeroWork =
          d.timetacTotal == Duration.zero && d.meetingsTotal == Duration.zero && d.leftover == Duration.zero;
      return !(zeroWork && !hasAnyAbsence(d));
    }).toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    if (visible.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text('Keine Tage mit Inhalt.'),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Expanded(child: Text('Datum', style: TextStyle(fontWeight: FontWeight.bold))),
            Expanded(child: Text('Timetac', style: TextStyle(fontWeight: FontWeight.bold))),
            Expanded(child: Text('Meetings', style: TextStyle(fontWeight: FontWeight.bold))),
            Expanded(child: Text('Abwesenheit', style: TextStyle(fontWeight: FontWeight.bold))),
            Expanded(child: Text('Arbeit', style: TextStyle(fontWeight: FontWeight.bold))),
          ]),
          const Divider(),
          for (final d in visible)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4.0),
              child: Row(children: [
                Expanded(
                  child: Text(
                    '${d.date.year}-${d.date.month.toString().padLeft(2, '0')}-${d.date.day.toString().padLeft(2, '0')}',
                  ),
                ),
                Expanded(child: Text(fmt(d.timetacTotal))),
                Expanded(child: Text(fmt(d.meetingsTotal))),
                Expanded(child: Text(absenceLabel(d))),
                Expanded(child: Text(fmt(d.leftover))),
              ]),
            ),
        ]),
      ),
    );
  }
}
