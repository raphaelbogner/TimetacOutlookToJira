import 'dart:convert';
import '../models/models.dart';

class TimetacCsvParser {
  static List<TimetacRow> parseWithConfig(List<int> bytes, SettingsModel s) {
    final text = utf8.decode(bytes, allowMalformed: true);
    final lines = const LineSplitter().convert(text);
    if (lines.isEmpty) return [];

    final delimiter = s.csvDelimiter.isNotEmpty ? s.csvDelimiter : ';';

    List<String>? header;
    var startRow = 0;

    // Defaults nach deiner bisherigen Index-Logik
    int idxDesc = 28, idxDate = 4, idxStart = 7, idxEnd = 8, idxDur = 18;
    int idxPauseTotal = 9, idxPauseRanges = 10;
    int idxAbsenceTotal = 18, idxSick = 25, idxHoliday = 24, idxVacationHours = 23, idxTimeCompensationHours = 21;

    if (s.csvHasHeader && lines.isNotEmpty) {
      header = _splitCsvLine(lines.first, delimiter);
      startRow = 1;

      idxDesc = _resolveIndex(s.csvColDescription, header, fallback: idxDesc);
      idxDate = _resolveIndex(s.csvColDate, header, fallback: idxDate);
      idxStart = _resolveIndex(s.csvColStart, header, fallback: idxStart);
      idxEnd = _resolveIndex(s.csvColEnd, header, fallback: idxEnd);
      idxDur = _resolveIndex(s.csvColDuration, header, fallback: idxDur);
      idxPauseTotal = _resolveIndex(s.csvColPauseTotal, header, fallback: idxPauseTotal);
      idxPauseRanges = _resolveIndex(s.csvColPauseRanges, header, fallback: idxPauseRanges);
      idxAbsenceTotal = _resolveIndex(s.csvColAbsenceTotal, header, fallback: idxAbsenceTotal);
      idxSick = _resolveIndex(s.csvColSick, header, fallback: idxSick);
      idxHoliday = _resolveIndex(s.csvColHoliday, header, fallback: idxHoliday);
      idxVacationHours = _resolveIndex(s.csvColVacation, header, fallback: idxVacationHours);
      idxTimeCompensationHours = _resolveIndex(s.csvColTimeCompensation, header, fallback: idxTimeCompensationHours);

      // Fallback RA/SA → K/G
      if (!_validIndex(idxStart, header.length)) {
        final kIdx = header.indexWhere((h) => _norm(h) == 'k');
        if (kIdx >= 0) idxStart = kIdx;
      }
      if (!_validIndex(idxEnd, header.length)) {
        final gIdx = header.indexWhere((h) => _norm(h) == 'g');
        if (gIdx >= 0) idxEnd = gIdx;
      }
    } else {
      // Kein Header: Spalten per Index (wenn Zahlen in Settings stehen)
      idxDesc = _resolveIndex(s.csvColDescription, null, fallback: idxDesc);
      idxDate = _resolveIndex(s.csvColDate, null, fallback: idxDate);
      idxStart = _resolveIndex(s.csvColStart, null, fallback: idxStart);
      idxEnd = _resolveIndex(s.csvColEnd, null, fallback: idxEnd);
      idxDur = _resolveIndex(s.csvColDuration, null, fallback: idxDur);
      idxPauseTotal = _resolveIndex(s.csvColPauseTotal, null, fallback: idxPauseTotal);
      idxPauseRanges = _resolveIndex(s.csvColPauseRanges, null, fallback: idxPauseRanges);
      idxAbsenceTotal = _resolveIndex(s.csvColAbsenceTotal, null, fallback: idxAbsenceTotal);
      idxSick = _resolveIndex(s.csvColSick, null, fallback: idxSick);
      idxHoliday = _resolveIndex(s.csvColHoliday, null, fallback: idxHoliday);
      idxVacationHours = _resolveIndex(s.csvColVacation, null, fallback: idxVacationHours);
      idxTimeCompensationHours = _resolveIndex(s.csvColTimeCompensation, null, fallback: idxTimeCompensationHours);
    }

    // Parser-Helfer
    double parseDays(String v) {
      final t = v.trim().replaceAll(',', '.');
      return double.tryParse(t) ?? 0.0;
    }

    Duration parseHoursDecimal(String v) {
      final t = v.trim().replaceAll(',', '.');
      final x = double.tryParse(t) ?? 0.0;
      return Duration(minutes: (x * 60).round());
    }

    final rows = <TimetacRow>[];

    for (var r = startRow; r < lines.length; r++) {
      final raw = lines[r].trim();
      if (raw.isEmpty) continue;

      final parts = _splitCsvLine(raw, delimiter);

      final needLen = <int>[
        idxDesc,
        idxDate,
        idxStart,
        idxEnd,
        idxDur,
        idxPauseTotal,
        idxPauseRanges,
        idxAbsenceTotal,
        idxSick,
        idxHoliday,
        idxVacationHours,
        idxTimeCompensationHours
      ].where((i) => i >= 0).fold<int>(0, (p, i) => i > p ? i : p);

      while (parts.length <= needLen) {
        parts.add('');
      }

      final desc = _get(parts, idxDesc);
      if (desc.toLowerCase().startsWith('summe')) continue;

      final dateStr = _get(parts, idxDate);
      final startStr = _get(parts, idxStart);
      final endStr = _get(parts, idxEnd);
      final durStr = _get(parts, idxDur);
      final pTotalStr = _get(parts, idxPauseTotal);
      final pRangesStr = _get(parts, idxPauseRanges);

      DateTime? date = _tryParseDate(dateStr);
      DateTime? start = _tryParseDateTime(startStr) ?? _combineDateAndTime(date, startStr);
      DateTime? end = _tryParseDateTime(endStr) ?? _combineDateAndTime(date, endStr);

      date ??= (start != null) ? DateTime(start.year, start.month, start.day) : null;

      var duration = Duration.zero;
      final parsedDur = _parseDurationFlexible(durStr);
      if (parsedDur != null) duration = parsedDur;
      if (start != null && end != null && end.isAfter(start)) {
        duration = end.difference(start);
      }

      final pauseTotal = _parseDurationFlexible(pTotalStr) ?? Duration.zero;

      final pauses = <TimeRange>[];
      if (pRangesStr.isNotEmpty && date != null) {
        for (final chunk in _splitPauseRanges(pRangesStr)) {
          final t = chunk.trim();
          if (t.isEmpty) continue;
          final dash = t.indexOf('-');
          if (dash <= 0) continue;
          final a = t.substring(0, dash).trim();
          final b = t.substring(dash + 1).trim();
          final sdt = _combineDateAndTime(date, a);
          final edt = _combineDateAndTime(date, b);
          if (sdt != null && edt != null && edt.isAfter(sdt)) {
            pauses.add(TimeRange(sdt, edt));
          }
        }
      }

      if (date == null) continue;

      final absence = (idxAbsenceTotal >= 0) ? parseHoursDecimal(_get(parts, idxAbsenceTotal)) : Duration.zero;
      final sick = (idxSick >= 0) ? parseDays(_get(parts, idxSick)) : 0.0;
      final holiday = (idxHoliday >= 0) ? parseDays(_get(parts, idxHoliday)) : 0.0;
      final vacation = (idxVacationHours >= 0) ? parseHoursDecimal(_get(parts, idxVacationHours)) : Duration.zero;
      final timeCpomensation =
          (idxTimeCompensationHours >= 0) ? parseHoursDecimal(_get(parts, idxTimeCompensationHours)) : Duration.zero;

      rows.add(TimetacRow(
        description: desc,
        date: DateTime(date.year, date.month, date.day),
        start: start,
        end: end,
        duration: duration,
        pauseTotal: pauseTotal,
        pauses: pauses,
        absenceTotal: absence,
        sickDays: sick,
        holidayDays: holiday,
        vacationHours: vacation,
        timeCompensationHours: timeCpomensation,
      ));
    }

    return rows;
  }

  // ---------- Helpers ----------
  static List<String> _splitCsvLine(String line, String delimiter) {
    final out = <String>[];
    final d = delimiter.codeUnitAt(0);
    final q = '"'.codeUnitAt(0);

    final codeUnits = line.codeUnits;
    final buf = <int>[];
    var inQuotes = false;

    for (var i = 0; i < codeUnits.length; i++) {
      final c = codeUnits[i];
      if (c == q) {
        // doppelte Quotes "" -> ein Quote in Feld
        if (inQuotes && i + 1 < codeUnits.length && codeUnits[i + 1] == q) {
          buf.add(q);
          i++; // skip next
        } else {
          inQuotes = !inQuotes;
        }
      } else if (c == d && !inQuotes) {
        out.add(String.fromCharCodes(buf));
        buf.clear();
      } else {
        buf.add(c);
      }
    }
    out.add(String.fromCharCodes(buf));
    return out;
  }

  static Iterable<String> _splitPauseRanges(String field) {
    // Der gesamte Feldinhalt kann quotes enthalten – hier sind sie schon entfernt
    // (weil _splitCsvLine Quotes nicht mitliefert). Splitte auf ';'.
    return field.split(';');
  }

  static String _get(List<String> parts, int idx) => (idx >= 0 && idx < parts.length) ? parts[idx].trim() : '';

  static bool _validIndex(int idx, int len) => idx >= 0 && idx < len;

  static int _resolveIndex(String setting, List<String>? header, {required int fallback}) {
    final s = setting.trim();
    if (s.isEmpty) return fallback;
    // Zahl -> direkter Index
    final asNum = int.tryParse(s);
    if (asNum != null) return asNum;
    // Name -> in Header suchen
    if (header != null) {
      final i = header.indexWhere((h) => _norm(h) == _norm(s));
      if (i >= 0) return i;
    }
    return fallback;
  }

  static String _norm(String s) => s.toLowerCase().trim();

  // ---------- Date/Time helpers ----------
  static DateTime? _tryParseDate(String s) {
    if (s.isEmpty) return null;
    try {
      if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)) {
        final d = DateTime.parse(s);
        return DateTime(d.year, d.month, d.day);
      }
      if (RegExp(r'^\d{2}\.\d{2}\.\d{4}$').hasMatch(s)) {
        final p = s.split('.');
        return DateTime(int.parse(p[2]), int.parse(p[1]), int.parse(p[0]));
      }
    } catch (_) {}
    return null;
  }

  static DateTime? _tryParseDateTime(String s) {
    if (s.isEmpty) return null;
    try {
      if (RegExp(r'^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}$').hasMatch(s)) {
        return DateTime.parse(s.replaceFirst(' ', 'T'));
      }
      if (RegExp(r'^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}$').hasMatch(s)) {
        return DateTime.parse('${s.replaceFirst(' ', 'T')}:00');
      }
      if (RegExp(r'^\d{2}\.\d{2}\.\d{4} \d{2}:\d{2}(:\d{2})?$').hasMatch(s)) {
        final parts = s.split(' ');
        final d = parts[0].split('.');
        final t = parts[1].split(':');
        final sec = t.length >= 3 ? int.parse(t[2]) : 0;
        return DateTime(int.parse(d[2]), int.parse(d[1]), int.parse(d[0]), int.parse(t[0]), int.parse(t[1]), sec);
      }
    } catch (_) {}
    return null;
  }

  static DateTime? _combineDateAndTime(DateTime? date, String timeOnly) {
    if (date == null || timeOnly.isEmpty) return null;
    if (!RegExp(r'^\d{1,2}:\d{2}(:\d{2})?$').hasMatch(timeOnly)) return null;
    final parts = timeOnly.split(':');
    final h = int.parse(parts[0]), m = int.parse(parts[1]);
    final s = parts.length >= 3 ? int.parse(parts[2]) : 0;
    return DateTime(date.year, date.month, date.day, h, m, s);
  }

  static Duration? _parseDurationFlexible(String s) {
    final v = s.trim().replaceAll(',', '.');
    if (v.isEmpty) return null;
    if (RegExp(r'^\d+(\.\d+)?$').hasMatch(v)) {
      final h = double.tryParse(v);
      if (h != null) return Duration(minutes: (h * 60).round());
    }
    if (RegExp(r'^\d{1,2}:\d{2}$').hasMatch(v)) {
      final a = v.split(':');
      return Duration(hours: int.parse(a[0]), minutes: int.parse(a[1]));
    }
    return null;
  }
}
