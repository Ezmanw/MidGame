import 'package:flutter/material.dart';

/// Full-height picker over the 128 General MIDI programs, grouped by family.
Future<int?> showProgramPicker(
  BuildContext context, {
  required List<String> programs,
  required List<String> families,
  required int current,
}) {
  return showDialog<int>(
    context: context,
    builder: (_) => _ProgramPicker(
      programs: programs,
      families: families,
      current: current,
    ),
  );
}

class _ProgramPicker extends StatefulWidget {
  const _ProgramPicker({
    required this.programs,
    required this.families,
    required this.current,
  });

  final List<String> programs;
  final List<String> families;
  final int current;

  @override
  State<_ProgramPicker> createState() => _ProgramPickerState();
}

class _ProgramPickerState extends State<_ProgramPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _query.trim().toLowerCase();

    // Keep the family headers, but drop families with nothing matching.
    final sections = <(String, List<(int, String)>)>[];
    for (var f = 0; f < widget.families.length; f++) {
      final entries = <(int, String)>[];
      for (var i = f * 8; i < (f + 1) * 8 && i < widget.programs.length; i++) {
        if (query.isEmpty ||
            widget.programs[i].toLowerCase().contains(query) ||
            widget.families[f].toLowerCase().contains(query)) {
          entries.add((i, widget.programs[i]));
        }
      }
      if (entries.isNotEmpty) sections.add((widget.families[f], entries));
    }

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Choose an instrument',
                        style: theme.textTheme.headlineSmall),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                    tooltip: 'Close',
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: SearchBar(
                hintText: 'Search 128 sounds',
                leading: const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(Icons.search),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: sections.isEmpty
                  ? Center(
                      child: Text('No sound matches “$_query”',
                          style: theme.textTheme.bodyMedium),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      children: [
                        for (final (family, entries) in sections) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
                            child: Text(
                              family.toUpperCase(),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.primary,
                                letterSpacing: 1.1,
                              ),
                            ),
                          ),
                          for (final (index, name) in entries)
                            ListTile(
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                              selected: index == widget.current,
                              selectedTileColor: theme.colorScheme.secondaryContainer,
                              leading: SizedBox(
                                width: 32,
                                child: Text('$index',
                                    textAlign: TextAlign.right,
                                    style: theme.textTheme.labelMedium?.copyWith(
                                        color: theme.colorScheme.onSurfaceVariant)),
                              ),
                              title: Text(name),
                              trailing: index == widget.current
                                  ? const Icon(Icons.check)
                                  : null,
                              onTap: () => Navigator.pop(context, index),
                            ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
