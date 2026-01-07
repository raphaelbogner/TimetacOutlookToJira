// lib/services/ics_parser.dart
import 'dart:convert';

import 'package:flutter_jira_timetac/models/models.dart';

// =======================================================
//                Configurable Non-Meeting Hints
// =======================================================
List<String> _nonMeetingHints = SettingsModel.defaultNonMeetingHintsList;

// Version-Token für Cache-Invalidierung
int _hintsVersionGlobal = 0;

/// Von außen aufrufbar: setzt Hints und invalidiert interne Caches.
void setNonMeetingHints(List<String> hints) {
  _nonMeetingHints = hints.map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty).toList(growable: false);
  _hintsVersionGlobal++; // Caches merken Änderung
  _dayCache.onHintsChanged(); // Day-Cache leeren
  _fastCache.onHintsChanged(); // Range-Cache leeren
}

List<String> getNonMeetingHints() => List.unmodifiable(_nonMeetingHints);

// =======================================================
//                 ICS DATA STRUCTURES
// =======================================================

class IcsEvent {
  IcsEvent({
    required this.start,
    required this.end,
    required this.summary,
    required this.allDay,
    this.status,
    this.transp,
    this.busyStatus,
    this.uid,
    this.rrule,
    this.categories,
    this.description,
    this.attendeeCount = 0,
    this.selfPartstat,
    this.recurrenceId,
    List<DateTime>? exdates,
  }) : exdates = exdates ?? [];

  DateTime start;
  DateTime end;
  String summary;
  bool allDay;

  String? status;
  String? transp;
  String? busyStatus;
  String? uid;
  String? rrule;
  String? categories;
  String? description;

  /// reine Zählung – wird nur als schneller Filter genutzt
  int attendeeCount;

  /// eigener Teilnahme-Status (ACCEPTED / NEEDS-ACTION / TENTATIVE / DECLINED …)
  String? selfPartstat;

  List<DateTime> exdates;

  DateTime? recurrenceId;

  Duration get duration => end.difference(start);
}

extension IcsEventFlags on IcsEvent {
  bool get isLikelyCancelledOrDeclined {
    final s = (status ?? '').toUpperCase();
    if (s.contains('CANCEL')) return true;

    final title = summary.toLowerCase();
    final desc = (description ?? '').toLowerCase();
    if (title.contains('abgesagt') ||
        title.contains('canceled') ||
        title.contains('cancelled') ||
        desc.contains('abgesagt') ||
        desc.contains('canceled') ||
        desc.contains('cancelled')) {
      return true;
    }

    // Teilnahme-Status härter auswerten
    final ps = selfPartstat?.toUpperCase();
    if (ps != null && ps != 'NEEDS-ACTION' && ps != 'ACCEPTED' && ps != 'TENTATIVE') {
      // z.B. DECLINED, DELEGATED, COMPLETED, IN-PROCESS ...
      return true;
    }

    return false;
  }
}

class IcsParseResult {
  IcsParseResult(this.events);
  final List<IcsEvent> events;
}

// =======================================================
//                 HELPERS / FILTERS
// =======================================================

DateTime _parseIcsDateTimeFlexible(String v) {
  String ts = v.trim();
  final colon = ts.indexOf(':');
  if (colon >= 0) ts = ts.substring(colon + 1).trim();

  if (RegExp(r'^\d{8}$').hasMatch(ts)) {
    final y = int.parse(ts.substring(0, 4));
    final m = int.parse(ts.substring(4, 6));
    final d = int.parse(ts.substring(6, 8));
    return DateTime(y, m, d);
  }

  final mBasic = RegExp(r'^(\d{8})T(\d{4})(\d{2})?(Z)?$').firstMatch(ts);
  if (mBasic != null) {
    final d8 = mBasic.group(1)!;
    final hm = mBasic.group(2)!;
    final ss = mBasic.group(3);
    final z = mBasic.group(4) == 'Z';

    final y = int.parse(d8.substring(0, 4));
    final mo = int.parse(d8.substring(4, 6));
    final d = int.parse(d8.substring(6, 8));
    final hh = int.parse(hm.substring(0, 2));
    final mm = int.parse(hm.substring(2, 4));
    final s = ss != null ? int.parse(ss) : 0;

    return z ? DateTime.utc(y, mo, d, hh, mm, s).toLocal() : DateTime(y, mo, d, hh, mm, s);
  }

  // ISO 8601 Fallback
  final dt = DateTime.parse(ts);
  return dt.isUtc ? dt.toLocal() : dt;
}

bool _isCancelled(IcsEvent e) {
  final s = (e.status ?? '').toUpperCase();
  if (s.contains('CANCELLED')) return true;
  final t = (e.summary).toLowerCase();
  return t.contains('abgesagt') || t.contains('canceled') || t.contains('cancelled');
}

bool _isAllDayDayOff(IcsEvent e) {
  if (!e.allDay) return false;
  final t = e.summary.toLowerCase();
  if (t.contains('homeoffice') || t.contains('an anderem ort')) return false;
  if (t.contains('urlaub') || t.contains('feiertag') || t.contains('krank')) return true;
  final busy = (e.busyStatus ?? '').toUpperCase();
  if (busy == 'OOF') return true;
  if (t.contains('abwesend')) return true;
  return false;
}

bool _crossesMidnight(IcsEvent e) => e.start.day != e.end.day || e.start.isAfter(e.end);
bool _tooLong(IcsEvent e) => e.duration > const Duration(hours: 10);

// =======================================================
//         RECURRENCE EXPANSION (Daily/Weekly + EXDATE)
// =======================================================

List<IcsEvent> _expandRecurringForWindow({
  required List<IcsEvent> recurring,
  required DateTime from,
  required DateTime to,
  Map<String, List<DateTime>> exceptionsByUid = const {},
}) {
  final out = <IcsEvent>[];

  for (final e in recurring) {
    final rule = e.rrule;
    if (rule == null || rule.trim().isEmpty) continue;

    // RRULE parsieren
    final parts = <String, String>{};
    for (final p in rule.split(';')) {
      final i = p.indexOf('=');
      if (i > 0) {
        parts[p.substring(0, i).toUpperCase()] = p.substring(i + 1);
      }
    }

    final freq = (parts['FREQ'] ?? '').toUpperCase();
    if (freq != 'DAILY' && freq != 'WEEKLY') {
      if (!(e.end.isBefore(from) || e.start.isAfter(to))) {
        out.add(e);
      }
      continue;
    }

    final until = parts['UNTIL'] != null ? _parseIcsDateTimeFlexible(parts['UNTIL']!) : null;
    final count = parts['COUNT'] != null ? int.tryParse(parts['COUNT']!) : null;
    final interval = parts['INTERVAL'] != null ? (int.tryParse(parts['INTERVAL']!) ?? 1) : 1;

    final rawByDay = parts['BYDAY'];
    final byday = (rawByDay != null && rawByDay.isNotEmpty)
        ? rawByDay.split(',').map((s) => s.toUpperCase().trim()).where((s) => s.isNotEmpty).toList()
        : (freq == 'WEEKLY'
            ? <String>[
                const {
                  DateTime.monday: 'MO',
                  DateTime.tuesday: 'TU',
                  DateTime.wednesday: 'WE',
                  DateTime.thursday: 'TH',
                  DateTime.friday: 'FR',
                  DateTime.saturday: 'SA',
                  DateTime.sunday: 'SU',
                }[e.start.weekday]!,
              ]
            : const <String>[]);

    bool matchesByDay(DateTime dt) {
      if (freq != 'WEEKLY') return true;
      const map = {
        DateTime.monday: 'MO',
        DateTime.tuesday: 'TU',
        DateTime.wednesday: 'WE',
        DateTime.thursday: 'TH',
        DateTime.friday: 'FR',
        DateTime.saturday: 'SA',
        DateTime.sunday: 'SU',
      };
      return byday.contains(map[dt.weekday]);
    }

    bool inInterval(DateTime dt) {
      if (interval <= 1) return true;
      final base = DateTime(e.start.year, e.start.month, e.start.day);
      final deltaDays = dt.difference(base).inDays;
      if (freq == 'DAILY') {
        return deltaDays % interval == 0;
      }
      if (freq == 'WEEKLY') {
        final weeks = deltaDays ~/ 7;
        return weeks % interval == 0;
      }
      return true;
    }

    final exdatesFromExceptions = e.uid != null ? (exceptionsByUid[e.uid!] ?? const <DateTime>[]) : const <DateTime>[];

    bool isExcluded(DateTime dt) {
      bool hit(List<DateTime> xs) => xs.any((ex) => ex.year == dt.year && ex.month == dt.month && ex.day == dt.day);
      return hit(e.exdates) || hit(exdatesFromExceptions);
    }

    var instStart = e.start;
    var instEnd = e.end;
    var emitted = 0;

    // Loop über alle möglichen Tage, bis wir aus dem Fenster raus sind
    while (true) {
      if (instStart.isAfter(to)) break;
      if (until != null && instStart.isAfter(until)) break;
      if (count != null && emitted >= count) break;

      final occurs = inInterval(instStart) &&
          (freq == 'DAILY' || (freq == 'WEEKLY' && matchesByDay(instStart))) &&
          !isExcluded(instStart);

      if (occurs) {
        emitted++; // COUNT zählt global

        if (!(instEnd.isBefore(from) || instStart.isAfter(to))) {
          out.add(IcsEvent(
            start: instStart,
            end: instEnd,
            summary: e.summary,
            allDay: e.allDay,
            status: e.status,
            transp: e.transp,
            busyStatus: e.busyStatus,
            uid: e.uid,
            rrule: e.rrule,
            categories: e.categories,
            description: e.description,
            attendeeCount: e.attendeeCount,
            selfPartstat: e.selfPartstat,
          ));
        }
      }

      // Preserve local time across DST boundaries by using calendar days
      // instead of adding 24 hours (which breaks during DST transitions)
      final eventDuration = instEnd.difference(instStart);
      instStart = DateTime(
        instStart.year,
        instStart.month,
        instStart.day + 1,
        instStart.hour,
        instStart.minute,
        instStart.second,
      );
      instEnd = instStart.add(eventDuration);
    }
  }

  return out;
}

// =======================================================
//                       PARSER
// =======================================================

IcsParseResult parseIcs(String content, {String selfEmail = ''}) {
  final self = selfEmail.trim().toLowerCase();

  // Zeilen-Folding zusammenführen
  final lines = const LineSplitter().convert(content).fold<List<String>>(<String>[], (acc, line) {
    if (line.startsWith(' ') || line.startsWith('\t')) {
      if (acc.isNotEmpty) acc[acc.length - 1] = acc.last + line.substring(1);
    } else {
      acc.add(line);
    }
    return acc;
  });

  final events = <IcsEvent>[];
  Map<String, String> cur = {};
  List<DateTime> exdates = [];
  int attendeeCount = 0;
  String? curSelfPartstat;
  DateTime? curRecurrenceId;
  bool inEvent = false;

  DateTime? valueDateToStart(String v) {
    if (v.length >= 8) {
      final y = int.parse(v.substring(0, 4));
      final m = int.parse(v.substring(4, 6));
      final d = int.parse(v.substring(6, 8));
      return DateTime(y, m, d);
    }
    return null;
  }

  DateTime? valueDateToEnd(String v) {
    final s = valueDateToStart(v);
    if (s == null) return null;
    return s.add(const Duration(days: 1));
  }

  for (final raw in lines) {
    if (raw == 'BEGIN:VEVENT') {
      inEvent = true;
      cur = {};
      exdates = [];
      attendeeCount = 0;
      curSelfPartstat = null;
      curRecurrenceId = null;
      continue;
    }
    if (raw == 'END:VEVENT') {
      inEvent = false;

      final sum = cur['SUMMARY'] ?? cur['SUMMARY;LANGUAGE=de'] ?? '';
      final status = cur['STATUS'];
      final transp = cur['TRANSP'];
      final busy = cur['X-MICROSOFT-CDO-BUSYSTATUS'] ?? cur['BUSYSTATUS'];
      final uid = cur['UID'];
      final rrule = cur['RRULE'];
      final categories = cur['CATEGORIES'];
      final description = cur['DESCRIPTION'];

      DateTime? dtStart;
      DateTime? dtEnd;
      bool allDay = false;

      if (cur.containsKey('DTSTART')) {
        dtStart = _parseIcsDateTimeFlexible(cur['DTSTART']!);
      } else if (cur.keys.any((k) => k.startsWith('DTSTART;VALUE=DATE'))) {
        final k = cur.keys.firstWhere((k) => k.startsWith('DTSTART;VALUE=DATE'));
        final v = cur[k]!;
        dtStart = valueDateToStart(v);
        allDay = true;
      } else if (cur.keys.any((k) => k.startsWith('DTSTART;TZID'))) {
        final k = cur.keys.firstWhere((k) => k.startsWith('DTSTART;TZID'));
        dtStart = _parseIcsDateTimeFlexible(cur[k]!);
      }

      if (cur.containsKey('DTEND')) {
        dtEnd = _parseIcsDateTimeFlexible(cur['DTEND']!);
      } else if (cur.keys.any((k) => k.startsWith('DTEND;VALUE=DATE'))) {
        final k = cur.keys.firstWhere((k) => k.startsWith('DTEND;VALUE=DATE'));
        final v = cur[k]!;
        dtEnd = valueDateToEnd(v);
        allDay = true;
      } else if (cur.keys.any((k) => k.startsWith('DTEND;TZID'))) {
        final k = cur.keys.firstWhere((k) => k.startsWith('DTEND;TZID'));
        dtEnd = _parseIcsDateTimeFlexible(cur[k]!);
      }

      if (dtStart != null && dtEnd != null) {
        events.add(IcsEvent(
          start: dtStart,
          end: dtEnd,
          summary: sum,
          allDay: allDay,
          status: status,
          transp: transp,
          busyStatus: busy,
          uid: uid,
          rrule: rrule,
          categories: categories,
          description: description,
          attendeeCount: attendeeCount,
          selfPartstat: curSelfPartstat,
          exdates: exdates,
          recurrenceId: curRecurrenceId,
        ));
      }
      continue;
    }

    if (!inEvent) continue;

    if (raw.startsWith('RECURRENCE-ID')) {
      final idx = raw.indexOf(':');
      if (idx > 0) {
        final v = raw.substring(idx + 1);
        curRecurrenceId = _parseIcsDateTimeFlexible(v);
      }
      continue;
    }

    if (raw.startsWith('EXDATE')) {
      final idx = raw.indexOf(':');
      if (idx > 0) {
        final v = raw.substring(idx + 1);
        for (final part in v.split(',')) {
          final s = part.trim();
          if (s.length == 8) {
            final y = int.parse(s.substring(0, 4));
            final m = int.parse(s.substring(4, 6));
            final d = int.parse(s.substring(6, 8));
            exdates.add(DateTime(y, m, d));
          } else {
            exdates.add(_parseIcsDateTimeFlexible(s));
          }
        }
      }
      continue;
    }

    if (raw.startsWith('ATTENDEE')) {
      attendeeCount++;

      // Nur eigenen Status mitschneiden
      final idx = raw.indexOf(':');
      String params, addr;
      if (idx > 0) {
        params = raw.substring(0, idx);
        addr = raw.substring(idx + 1).trim();
      } else {
        params = raw;
        addr = '';
      }

      String? partstat;
      for (final p in params.split(';')) {
        final kv = p.split('=');
        if (kv.length == 2 && kv.first.toUpperCase().trim() == 'PARTSTAT') {
          partstat = kv.last.trim();
        }
      }

      String email = '';
      final lower = addr.toLowerCase();
      if (lower.startsWith('mailto:')) {
        email = lower.substring('mailto:'.length).trim();
      } else {
        email = lower.trim();
      }

      if (self.isNotEmpty && email == self) {
        curSelfPartstat = partstat?.toUpperCase();
      }
      continue;
    }

    final i = raw.indexOf(':');
    if (i > 0) {
      final k = raw.substring(0, i);
      final v = raw.substring(i + 1);
      cur.putIfAbsent(k, () => v);
      if (k.startsWith('SUMMARY;')) cur.putIfAbsent('SUMMARY', () => v);
    }
  }

  return IcsParseResult(events);
}

// =======================================================
//             DAY CACHE (single-day, generic)
// =======================================================

class DayCalendar {
  DayCalendar({required this.meetings, required this.dayOff});
  final List<IcsEvent> meetings;
  final bool dayOff;
}

class _IcsDayCache {
  final Map<int, DayCalendar> _cache = <int, DayCalendar>{};

  // lokale Version, um bei Änderungen zu invalidieren
  int _hintsVersionLocal = _hintsVersionGlobal;

  void clear() => _cache.clear();

  // vom Setter aufgerufen
  void onHintsChanged() {
    _hintsVersionLocal = _hintsVersionGlobal;
    clear();
  }

  DayCalendar getOrCompute(List<IcsEvent> allEvents, DateTime day) {
    if (_hintsVersionLocal != _hintsVersionGlobal) {
      onHintsChanged();
    }

    final key = DateTime(day.year, day.month, day.day).millisecondsSinceEpoch;
    final cached = _cache[key];
    if (cached != null) return cached;

    final from = DateTime(day.year, day.month, day.day);
    final to = from.add(const Duration(days: 1)).subtract(const Duration(milliseconds: 1));

    final simple = <IcsEvent>[];
    final recurring = <IcsEvent>[];
    final exceptionsByUid = <String, List<DateTime>>{};

    for (final e in allEvents) {
      final hasRrule = (e.rrule ?? '').trim().isNotEmpty;
      final hasRecurrenceId = e.recurrenceId != null;

      if (hasRrule) {
        recurring.add(e);
      } else {
        simple.add(e);
      }

      if (hasRecurrenceId && e.uid != null && e.isLikelyCancelledOrDeclined) {
        (exceptionsByUid[e.uid!] ??= []).add(e.recurrenceId!);
      }
    }

    final candidates = <IcsEvent>[
      ...simple.where((e) => !(e.end.isBefore(from) || e.start.isAfter(to))),
      ..._expandRecurringForWindow(
        recurring: recurring,
        from: from,
        to: to,
        exceptionsByUid: exceptionsByUid,
      ),
    ];

    final hasDayOff = candidates.any(_isAllDayDayOff);

    final meetings = candidates.where((e) {
      // Alles was sehr wahrscheinlich storniert / abgelehnt ist, fliegt raus
      if (e.isLikelyCancelledOrDeclined) return false;
      // zusätzlicher, konservativer Legacy-Check
      if (_isCancelled(e)) return false;

      if (e.allDay) return false;
      if (_crossesMidnight(e)) return false;
      if (_tooLong(e)) return false;

      final transpUpper = (e.transp ?? '').toUpperCase();
      if (transpUpper == 'TRANSPARENT') return false;

      final busyUpper = (e.busyStatus ?? '').toUpperCase();
      if (busyUpper == 'FREE' || busyUpper == 'WORKINGELSEWHERE' || busyUpper == 'OOF') {
        return false;
      }

      final isExceptionInstance = e.recurrenceId != null;

      if (e.attendeeCount == 0 && !isExceptionInstance) return false;

      final title = e.summary.trim().toLowerCase();
      if (title.isEmpty || _nonMeetingHints.any((k) => title.contains(k))) return false;

      final s = e.start.isBefore(from) ? from : e.start;
      final ed = e.end.isAfter(to) ? to : e.end;
      return ed.isAfter(s);
    }).map((e) {
      final s = e.start.isBefore(from) ? from : e.start;
      final ed = e.end.isAfter(to) ? to : e.end;
      return IcsEvent(
        start: s,
        end: ed,
        summary: e.summary,
        allDay: false,
        status: e.status,
        transp: e.transp,
        busyStatus: e.busyStatus,
        uid: e.uid,
        rrule: e.rrule,
        categories: e.categories,
        description: e.description,
        attendeeCount: e.attendeeCount,
        selfPartstat: e.selfPartstat,
      );
    }).toList()
      ..sort((a, b) => a.start.compareTo(b.start));

    final merged = <IcsEvent>[];
    for (final m in meetings) {
      if (merged.isEmpty) {
        merged.add(m);
      } else {
        final last = merged.last;

        final sameUid = last.uid != null && last.uid == m.uid;
        if (sameUid && m.start.isBefore(last.end)) {
          final newEnd = m.end.isAfter(last.end) ? m.end : last.end;
          merged[merged.length - 1] = IcsEvent(
            start: last.start,
            end: newEnd,
            summary: '${last.summary} + ${m.summary}',
            allDay: false,
            status: last.status,
            transp: last.transp,
            busyStatus: last.busyStatus,
            uid: last.uid,
            rrule: last.rrule,
            categories: last.categories,
            description: last.description,
            attendeeCount: last.attendeeCount,
            selfPartstat: last.selfPartstat,
          );
        } else {
          merged.add(m);
        }
      }
    }

    final dc = DayCalendar(meetings: merged, dayOff: hasDayOff);
    _cache[key] = dc;
    return dc;
  }
}

final _IcsDayCache _dayCache = _IcsDayCache();
void clearIcsDayCache() => _dayCache.clear();
DayCalendar buildDayCalendarCached({required List<IcsEvent> allEvents, required DateTime day}) =>
    _dayCache.getOrCompute(allEvents, day);

// =======================================================
//             FAST RANGE CACHE (user-aware)
// =======================================================

class _UserRangeCache {
  String _userEmail = '';
  DateTime? _from; // inclusive 00:00
  DateTime? _to; // inclusive 23:59:59.999
  final Map<int, List<IcsEvent>> _bucket = <int, List<IcsEvent>>{};

  int _hintsVersionLocal = _hintsVersionGlobal;

  void clear() {
    _userEmail = '';
    _from = null;
    _to = null;
    _bucket.clear();
  }

  void onHintsChanged() {
    _hintsVersionLocal = _hintsVersionGlobal;
    clear();
  }

  bool _sameUser(String email) => _userEmail == email.trim().toLowerCase();

  bool covers(DateTime day, String userEmail) {
    if (_hintsVersionLocal != _hintsVersionGlobal) return false;
    if (!_sameUser(userEmail)) return false;
    if (_from == null || _to == null) return false;
    final d0 = DateTime(day.year, day.month, day.day);
    return !(d0.isBefore(_from!) || d0.isAfter(_to!));
  }

  List<IcsEvent> getDay(DateTime day, String userEmail) {
    if (!covers(day, userEmail)) return const <IcsEvent>[];
    final key = DateTime(day.year, day.month, day.day).millisecondsSinceEpoch;
    return _bucket[key] ?? const <IcsEvent>[];
  }

  void buildForRange({
    required List<IcsEvent> allEvents,
    required String userEmail,
    required DateTime from,
    required DateTime to,
  }) {
    if (_hintsVersionLocal != _hintsVersionGlobal) {
      onHintsChanged();
    }

    clear();

    _userEmail = userEmail.trim().toLowerCase();
    _from = DateTime(from.year, from.month, from.day);
    _to = DateTime(to.year, to.month, to.day, 23, 59, 59, 999);

    if (allEvents.isEmpty) return;

    var day = _from!;
    while (!day.isAfter(_to!)) {
      final dc = buildDayCalendarCached(allEvents: allEvents, day: day);
      if (dc.meetings.isNotEmpty) {
        final key = DateTime(day.year, day.month, day.day).millisecondsSinceEpoch;
        _bucket[key] = dc.meetings;
      }
      day = day.add(const Duration(days: 1));
    }
  }
}

final _UserRangeCache _fastCache = _UserRangeCache();

void clearIcsRangeCache() => _fastCache.clear();

void prepareUserMeetingsRange({
  required List<IcsEvent> allEvents,
  required String userEmail,
  required DateTime from,
  required DateTime to,
}) {
  _fastCache.buildForRange(allEvents: allEvents, userEmail: userEmail, from: from, to: to);
}

List<IcsEvent> meetingsForUserOnDayFast({
  required DateTime day,
  required String userEmail,
}) {
  return _fastCache.getDay(day, userEmail);
}

bool userRangeCacheCoversDay({required DateTime day, required String userEmail}) {
  return _fastCache.covers(day, userEmail);
}
