// lib/logic/worklog_builder.dart

class WorkWindow {
  DateTime start;
  DateTime end;
  Duration get duration => end.difference(start);

  WorkWindow(this.start, this.end);
}

class MeetingWindow extends WorkWindow {
  String title;

  MeetingWindow(
    super.start,
    super.end,
    this.title,
  );
}

enum DeltaState {
  newEntry,
  duplicate,
  overlap,
}

class DraftLog {
  DateTime start;
  DateTime end;
  String issueKey;
  String note;

  DeltaState deltaState;

  bool isManuallyModified;

  Duration get duration => end.difference(start);
  bool get isDuplicate => deltaState == DeltaState.duplicate;
  bool get isOverlap => deltaState == DeltaState.overlap;
  bool get isNew => deltaState == DeltaState.newEntry;

  DraftLog({
    required this.start,
    required this.end,
    required this.issueKey,
    required this.note,
    this.deltaState = DeltaState.newEntry,
    this.isManuallyModified = false,
  });

  DraftLog copy() => DraftLog(
        start: start,
        end: end,
        issueKey: issueKey,
        note: note,
        deltaState: deltaState,
        isManuallyModified: isManuallyModified,
      );
}

/// Merged überlappende oder direkt aneinanderstoßende Intervalle (Union).
List<WorkWindow> mergeWorkWindows(List<WorkWindow> windows) {
  if (windows.isEmpty) return const <WorkWindow>[];
  final sorted = List<WorkWindow>.from(windows)..sort((a, b) => a.start.compareTo(b.start));

  final merged = <WorkWindow>[sorted.first];
  for (var i = 1; i < sorted.length; i++) {
    final last = merged.last;
    final cur = sorted[i];

    // "touchesOrOverlaps": cur.start <= last.end  → zusammenführen
    if (!cur.start.isAfter(last.end)) {
      final newEnd = cur.end.isAfter(last.end) ? cur.end : last.end;
      merged[merged.length - 1] = WorkWindow(last.start, newEnd);
    } else {
      merged.add(cur);
    }
  }
  return merged;
}

List<WorkWindow> subtractIntervals(WorkWindow base, List<WorkWindow> cutters) {
  var pieces = <WorkWindow>[base];
  for (final c in cutters) {
    final next = <WorkWindow>[];
    for (final p in pieces) {
      final latestStart = p.start.isAfter(c.start) ? p.start : c.start;
      final earliestEnd = p.end.isBefore(c.end) ? p.end : c.end;
      final overlap = earliestEnd.isAfter(latestStart);
      if (!overlap) {
        next.add(p);
      } else {
        if (c.start.isAfter(p.start)) {
          next.add(WorkWindow(p.start, c.start));
        }
        if (c.end.isBefore(p.end)) {
          next.add(WorkWindow(c.end, p.end));
        }
      }
    }
    pieces = next;
  }
  return pieces.where((w) => w.duration.inSeconds >= 60).toList();
}

/// Optionaler Resolver, der für ein Arbeitsintervall die Issue bestimmt (z. B. via GitLab)
typedef FallbackIssueResolver = String? Function(DateTime start, DateTime end);

List<DraftLog> buildDraftsForDay({
  required DateTime day,
  required List<WorkWindow> workWindows,
  required List<MeetingWindow> meetings,
  required String meetingIssueKey,
  required String fallbackIssueKey,
  required String? meetingNotePrefix,
  required String? fallbackNote,
  FallbackIssueResolver? fallbackResolver,
}) {
  final drafts = <DraftLog>[];

  // ✨ Neu: Meetings zuerst union-mergen (verhindert künstliche Verlängerungen oder Doppelabzüge)
  final mergedMeetings =
      mergeWorkWindows(meetings).map((w) => w is MeetingWindow ? w : MeetingWindow(w.start, w.end, '')).toList();

  // Meetings: auf Arbeitsfenster clippen
  for (final m in mergedMeetings) {
    for (final w in workWindows) {
      final s = m.start.isAfter(w.start) ? m.start : w.start;
      final e = m.end.isBefore(w.end) ? m.end : w.end;
      if (e.isAfter(s)) {
        final label = meetingNotePrefix ?? 'Meeting';
        final title = (m.title.trim().isEmpty) ? '' : ' – ${m.title.trim()}';
        drafts.add(DraftLog(
          start: s,
          end: e,
          issueKey: meetingIssueKey,
          note: '$label ${_hhmm(s)}–${_hhmm(e)}$title',
        ));
      }
    }
  }

  // Arbeit = Arbeitsfenster minus (gemergte) Meetings
  final fallbackPieces = <WorkWindow>[];
  for (final w in workWindows) {
    final cuts = subtractIntervals(
      w,
      mergedMeetings.map((m) => WorkWindow(m.start, m.end)).toList(),
    );
    fallbackPieces.addAll(cuts);
  }

  for (final piece in fallbackPieces) {
    final issue = fallbackResolver?.call(piece.start, piece.end) ?? fallbackIssueKey;
    drafts.add(DraftLog(
      start: piece.start,
      end: piece.end,
      issueKey: issue,
      note: fallbackNote ?? 'Arbeit',
    ));
  }

  drafts.sort((a, b) => a.start.compareTo(b.start));
  return drafts;
}

String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
