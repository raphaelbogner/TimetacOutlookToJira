import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../logic/worklog_builder.dart';
import '../ui/preview_utils.dart'; // for formatDuration if needed, or just local

class DraftLogTile extends StatefulWidget {
  final DraftLog draft;
  final VoidCallback onChanged;
  final VoidCallback onSplit;
  final Function(bool up) onMerge;
  final bool canMergeUp;
  final bool canMergeDown;
  final Function(String) onTicketChanged;
  final Function(DateTime start, DateTime end) onTimeChanged;
  final VoidCallback onDelete;
  final Future<String?> Function() onPickTicket;
  final double? ticketWidth;

  const DraftLogTile({
    super.key,
    required this.draft,
    required this.onChanged,
    required this.onSplit,
    required this.onMerge,
    required this.canMergeUp,
    required this.canMergeDown,
    required this.onTicketChanged,
    required this.onTimeChanged,
    required this.onDelete,
    required this.onPickTicket,
    this.ticketWidth,
  });

  @override
  State<DraftLogTile> createState() => _DraftLogTileState();
}

class _DraftLogTileState extends State<DraftLogTile> {
  late TextEditingController _noteCtrl;
  final FocusNode _noteFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _noteCtrl = TextEditingController(text: widget.draft.note);
    _noteFocus.addListener(_onNoteFocusChange);
  }

  @override
  void didUpdateWidget(covariant DraftLogTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.draft != widget.draft) {
      if (_noteCtrl.text != widget.draft.note) {
        _noteCtrl.text = widget.draft.note;
      }
    }
  }

  @override
  void dispose() {
    _noteFocus.removeListener(_onNoteFocusChange);
    _noteCtrl.dispose();
    _noteFocus.dispose();
    super.dispose();
  }

  void _onNoteFocusChange() {
    if (!_noteFocus.hasFocus) {
      if (widget.draft.note != _noteCtrl.text) {
        widget.draft.note = _noteCtrl.text;
        widget.draft.isManuallyModified = true;
        widget.onChanged();
      }
    }
  }

  String _hhmm(DateTime t) => DateFormat('HH:mm').format(t);

  Future<void> _editTime(BuildContext context) async {
    // Simple dialog to edit start/end
    final startCtrl = TextEditingController(text: _hhmm(widget.draft.start));
    final endCtrl = TextEditingController(text: _hhmm(widget.draft.end));

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Zeit bearbeiten'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: startCtrl,
              decoration: const InputDecoration(labelText: 'Start (HH:mm)'),
            ),
            TextField(
              controller: endCtrl,
              decoration: const InputDecoration(labelText: 'Ende (HH:mm)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () {
              final s = _parseTime(startCtrl.text, widget.draft.start);
              final e = _parseTime(endCtrl.text, widget.draft.end);
              if (s != null && e != null && e.isAfter(s)) {
                widget.onTimeChanged(s, e);
                Navigator.pop(ctx);
              }
            },
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
  }

  DateTime? _parseTime(String hhmm, DateTime refDate) {
    final parts = hhmm.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return DateTime(refDate.year, refDate.month, refDate.day, h, m);
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    
    // Color logic - Pausen und bezahlte Nichtarbeitszeit sind immer gedimmt
    Color? statusColor;
    if (d.isPause || d.isDoctorAppointment) {
      statusColor = d.isDoctorAppointment ? Colors.amber.shade700 : Colors.grey.shade500;
    } else if (d.isDuplicate) {
      statusColor = Colors.grey;
    } else if (d.isOverlap) {
      statusColor = Colors.orange;
    }

    return GestureDetector(
      onSecondaryTapUp: (details) {
        if (!d.shouldSkipBooking) _showContextMenu(context, details.globalPosition);
      },
      child: Container(
        color: d.shouldSkipBooking ? (d.isDoctorAppointment ? Colors.amber.shade50.withAlpha(80) : Colors.grey.shade100.withAlpha(80)) : Colors.transparent,
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        child: Row(
          children: [
            // Status Icon
            if (d.isDoctorAppointment) const Tooltip(message: 'Bezahlte Nichtarbeitszeit (wird nicht gebucht)', child: Icon(Icons.schedule, size: 16, color: Colors.amber))
            else if (d.isPause) const Tooltip(message: 'Pause (wird nicht gebucht)', child: Icon(Icons.pause_circle_outline, size: 16, color: Colors.grey))
            else if (d.isManuallyModified) const Tooltip(message: 'Manuell bearbeitet', child: Icon(Icons.edit, size: 16, color: Colors.blue))
            else if (d.isNew) const Icon(Icons.fiber_new, size: 16, color: Colors.green)
            else if (d.isDuplicate) const Icon(Icons.check_circle, size: 16, color: Colors.grey)
            else if (d.isOverlap) const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange),
            
            const SizedBox(width: 8),

            // Ticket (nur für normale Worklogs)
            if (d.shouldSkipBooking)
              const SizedBox(width: 48) // Platzhalter für den Button
            else
              IconButton(
                icon: const Icon(Icons.swap_horiz, size: 20),
                tooltip: 'Ticket ändern',
                onPressed: () async {
                  final newKey = await widget.onPickTicket();
                  if (newKey != null && newKey.isNotEmpty) {
                    widget.onTicketChanged(newKey);
                  }
                },
              ),
            
            // Ticket Key Display oder "Pause"/"Arzttermin"
            SizedBox(
              width: widget.ticketWidth ?? 100,
              child: Text(
                d.isDoctorAppointment ? '' : (d.isPause ? '' : d.issueKey),
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: d.shouldSkipBooking ? FontWeight.normal : FontWeight.bold,
                  fontStyle: d.shouldSkipBooking ? FontStyle.italic : FontStyle.normal,
                  color: statusColor,
                ),
              ),
            ),

            // Time Range (Editable)
            InkWell(
              onTap: () => _editTime(context),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text(
                  '${_hhmm(d.start)}–${_hhmm(d.end)}',
                  style: TextStyle(fontFamily: 'monospace', color: statusColor),
                ),
              ),
            ),
            
            const SizedBox(width: 8),
            
            // Duration
            Text(
              '(${formatDuration(d.duration)})',
              style: TextStyle(fontFamily: 'monospace', color: Colors.grey.shade600),
            ),

            const SizedBox(width: 12),

            // Note (Editable) - with optional original title above
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Original title (if replaced) - small and crossed out
                  if (d.originalNote != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        d.originalNote!,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade500,
                          decoration: TextDecoration.lineThrough,
                          fontStyle: FontStyle.italic,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  // Editable note field
                  TextField(
                    controller: _noteCtrl,
                    focusNode: _noteFocus,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 8),
                    ),
                    style: TextStyle(color: statusColor),
                    onSubmitted: (_) {
                       // Trigger save on enter
                       _noteFocus.unfocus();
                    },
                  ),
                ],
              ),
            ),
            
            // Context Menu Button (Alternative to right click)
            IconButton(
              icon: const Icon(Icons.more_vert, size: 18),
              onPressed: () {
                // Find render box to position menu
                final renderBox = context.findRenderObject() as RenderBox;
                final offset = renderBox.localToGlobal(Offset.zero);
                _showContextMenu(context, offset + const Offset(300, 20)); // rough position
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showContextMenu(BuildContext context, Offset position) {
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      items: <PopupMenuEntry<dynamic>>[
        PopupMenuItem(
          onTap: widget.onSplit,
          child: const Row(
            children: [
              Icon(Icons.call_split, size: 18),
              SizedBox(width: 8),
              Text('Splitten (Halbieren)'),
            ],
          ),
        ),
        if (widget.canMergeUp)
          PopupMenuItem(
            onTap: () => widget.onMerge(true),
            child: const Row(
              children: [
                Icon(Icons.merge_type, size: 18), // Icon isn't perfect but works
                SizedBox(width: 8),
                Text('Mit Zeile darüber mergen'),
              ],
            ),
          ),
        if (widget.canMergeDown)
          PopupMenuItem(
            onTap: () => widget.onMerge(false),
            child: const Row(
              children: [
                Icon(Icons.merge_type, size: 18),
                SizedBox(width: 8),
                Text('Mit Zeile darunter mergen'),
              ],
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          onTap: widget.onDelete,
          child: const Row(
            children: [
              Icon(Icons.delete, size: 18, color: Colors.red),
              SizedBox(width: 8),
              Text('Löschen', style: TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ],
    );
  }
}
