import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../main.dart';
import '../services/delete_mode_service.dart';
import '../services/jira_worklog_api.dart';
import '../services/jira_api.dart';

class DeleteModeScreen extends StatefulWidget {
  const DeleteModeScreen({super.key});

  @override
  State<DeleteModeScreen> createState() => _DeleteModeScreenState();
}

class _DeleteModeScreenState extends State<DeleteModeScreen> {
  DateTime _currentMonth = DateTime.now();
  final Set<DateTime> _selectedDates = {};
  Map<String, List<JiraWorklog>> _worklogs = {};
  bool _loading = false;
  bool _deleting = false;
  String _statusMessage = '';

  @override
  void initState() {
    super.initState();
    // Start mit aktuellem Monat
    _loadMonth(_currentMonth);
  }

  DeleteModeService _getService(BuildContext context) {
    final state = context.read<AppState>();
    return DeleteModeService(
      jiraApi: JiraApi(
        baseUrl: state.settings.jiraBaseUrl,
        email: state.settings.jiraEmail,
        apiToken: state.settings.jiraApiToken,
      ),
      worklogApi: JiraWorklogApi(
        baseUrl: state.settings.jiraBaseUrl,
        email: state.settings.jiraEmail,
        apiToken: state.settings.jiraApiToken,
      ),
      currentUserAccountId: state.jiraAccountId ?? '',
    );
  }

  Future<void> _loadMonth(DateTime month) async {
    setState(() {
      _currentMonth = DateTime(month.year, month.month); // 1. des Monats
      _loading = true;
      _worklogs = {};
      _selectedDates.clear();
      _statusMessage = '';
    });

    final state = context.read<AppState>();
    if (!state.isJiraConfigured || state.jiraAccountId == null) {
      setState(() {
        _loading = false;
        _statusMessage = 'Jira nicht konfiguriert oder User unklar.';
      });
      return;
    }

    final start = DateTime(month.year, month.month, 1);
    // Ende des Monats: 1. des nächsten Monats minus 1 Tag
    final nextMonth = DateTime(month.year, month.month + 1, 1);
    final end = nextMonth.subtract(const Duration(days: 1));

    try {
      final srv = _getService(context);
      final res = await srv.fetchWorklogsForPeriod(start, end);
      if (mounted) {
        setState(() {
          _worklogs = res;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = 'Fehler beim Laden: $e';
          _loading = false;
        });
      }
    }
  }

  void _toggleDate(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    setState(() {
      if (_selectedDates.contains(d)) {
        _selectedDates.remove(d);
      } else {
        _selectedDates.add(d);
      }
    });
  }

  Future<void> _deleteSelected() async {
    final toDelete = <JiraWorklog>[];
    for (final d in _selectedDates) {
      final key = DateFormat('yyyy-MM-dd').format(d);
      if (_worklogs.containsKey(key)) {
        toDelete.addAll(_worklogs[key]!);
      }
    }

    if (toDelete.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Worklogs löschen?'),
        content: Text('Du bist dabei, ${toDelete.length} Zeitbuchungen an ${_selectedDates.length} Tagen zu löschen.\n\nDas kann nicht rückgängig gemacht werden!'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _deleting = true;
      _statusMessage = 'Lösche ${toDelete.length} Einträge...';
    });

    final srv = _getService(context);
    int Deleted = 0;
    int Failed = 0;

    for (final w in toDelete) {
      final ok = await srv.worklogApi.deleteWorklog(issueKeyOrId: w.issueKey, worklogId: w.id);
      if (ok) {
        Deleted++;
      } else {
        Failed++;
      }
      // Update status on fly? evtl. zu schnell
    }

    // Refresh
    await _loadMonth(_currentMonth);

    if (mounted) {
      setState(() {
        _deleting = false;
        _statusMessage = 'Fertig: $Deleted gelöscht, $Failed fehlgeschlagen.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Löschvorgang abgeschlossen: $Deleted gelöscht.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Jira Worklogs löschen'),
      ),
      body: Column(
        children: [
          _buildHeader(),
          if (_loading) const LinearProgressIndicator(),
          if (_statusMessage.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(_statusMessage, style: const TextStyle(color: Colors.red)),
            ),
          Expanded(child: _buildCalendar()),
          _buildBottomBar(),
        ],
      ),
      // Overlay when deleting
      // trivial implementiert via Stack im Body wäre schöner, aber so gehts auch:
      floatingActionButton: _deleting
          ? const FloatingActionButton(
              onPressed: null,
              child: CircularProgressIndicator(color: Colors.white),
            )
          : null,
    );
  }

  Future<void> _pickMonth() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _currentMonth,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDatePickerMode: DatePickerMode.year,
      helpText: 'Monat wählen (Tag egal)',
    );
    if (picked != null) {
      _loadMonth(picked);
    }
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: _loading || _deleting ? null : () {
              _loadMonth(DateTime(_currentMonth.year, _currentMonth.month - 1));
            },
          ),
          InkWell(
            onTap: _loading || _deleting ? null : _pickMonth,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
              child: Row(
                children: [
                  Text(
                    DateFormat('MMMM yyyy').format(_currentMonth),
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.arrow_drop_down),
                ],
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: _loading || _deleting ? null : () {
              _loadMonth(DateTime(_currentMonth.year, _currentMonth.month + 1));
            },
          ),
        ],
      ),
    );
  }

  Widget _buildCalendar() {
    // Einfache GridView für Tage
    // Header Zeile Mo-So
    // Dann Tage
    
    final daysInMonth = DateTime(_currentMonth.year, _currentMonth.month + 1, 0).day;
    final firstWeekday = DateTime(_currentMonth.year, _currentMonth.month, 1).weekday; // 1 = Mo, 7 = So

    final totalSlots = (firstWeekday - 1) + daysInMonth; // Offsets am Anfang
    final rows = (totalSlots / 7).ceil();
    
    return Column(
      children: [
        // Weekday Header
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: ['Mo','Di','Mi','Do','Fr','Sa','So'].map((s) => 
            SizedBox(width: 40, child: Center(child: Text(s, style: const TextStyle(fontWeight: FontWeight.bold))))
          ).toList(),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: rows * 7,
            itemBuilder: (ctx, index) {
              // Offset berechnen
              final dayOffset = index - (firstWeekday - 1);
              if (dayOffset < 0 || dayOffset >= daysInMonth) {
                return const SizedBox();
              }
              
              final day = dayOffset + 1;
              final date = DateTime(_currentMonth.year, _currentMonth.month, day);
              final key = DateFormat('yyyy-MM-dd').format(date);
              
              final hasLogs = _worklogs.containsKey(key) && _worklogs[key]!.isNotEmpty;
              final selected = _selectedDates.contains(date);
              
              Color? bgColor;
              if (selected) {
                bgColor = Theme.of(ctx).colorScheme.primaryContainer;
              } else if (hasLogs) {
                bgColor = Colors.green.withOpacity(0.3);
              } else {
                bgColor = Theme.of(ctx).cardColor;
              }
              
              return GestureDetector(
                onTap: _loading || _deleting ? null : () => _toggleDate(date),
                child: Container(
                  decoration: BoxDecoration(
                    color: bgColor,
                    border: selected ? Border.all(color: Theme.of(ctx).colorScheme.primary, width: 2) : Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: SizedBox(
                      width: 40, 
                      height: 40,
                      child: Stack(
                        children: [
                          Center(child: Text('$day', style: TextStyle(fontWeight: hasLogs ? FontWeight.bold : FontWeight.normal))),
                          if (hasLogs)
                            const Positioned(
                              bottom: 4,
                              right: 4,
                              child: Icon(Icons.access_time, size: 12, color: Colors.green),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildBottomBar() {
    final count = _selectedDates.length;
    int logsCount = 0;
    for (final d in _selectedDates) {
      final key = DateFormat('yyyy-MM-dd').format(d);
      if (_worklogs.containsKey(key)) {
        logsCount += _worklogs[key]!.length;
      }
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        boxShadow: [
          const BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, -2)),
        ],
      ),
      child: Row(
        children: [
          Expanded(child: Text('$count Tage ausgewählt ($logsCount Einträge)')),
          FilledButton.icon(
            onPressed: (_loading || _deleting || logsCount == 0) ? null : _deleteSelected,
            icon: const Icon(Icons.delete_forever),
            label: const Text('Löschen'),
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
          ),
        ],
      ),
    );
  }
}
