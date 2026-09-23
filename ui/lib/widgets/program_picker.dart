import 'package:flutter/material.dart';

/// Where the list was last left, so reopening the picker does not throw the
/// user back to the top of 128 sounds.
double _lastOffset = 0;

/// Picker over the 128 General MIDI programs, grouped by family.
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
  static const double _rowHeight = 48;
  static const double _headerHeight = 34;

  late final ScrollController _scroll;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController(initialScrollOffset: _restoreOffset());
    _scroll.addListener(() {
      if (_query.isEmpty && _scroll.hasClients) _lastOffset = _scroll.offset;
    });
  }

  /// Open where the user left off, unless the selection is elsewhere - then
  /// show the selection, roughly a third of the way down.
  double _restoreOffset() {
    final family = widget.current ~/ 8;
    final selected =
        family * _headerHeight + widget.current * _rowHeight - _rowHeight * 3;
    final visible = _lastOffset > 0 &&
        (selected - _lastOffset).abs() < 400; // already roughly on screen
    return (visible ? _lastOffset : selected).clamp(0.0, double.infinity);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _query.trim().toLowerCase();

    // Keep family headers, but drop families with nothing matching.
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
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Column(
          children: [
            // Header and search sit on their own surface so list rows scroll
            // underneath them rather than bleeding through.
            Material(
              color: theme.colorScheme.surfaceContainerHigh,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text('Choose an instrument',
                              style: theme.textTheme.titleLarge),
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
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: SearchBar(
                      hintText: 'Search 128 sounds',
                      elevation: const WidgetStatePropertyAll(0),
                      leading: const Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: Icon(Icons.search),
                      ),
                      onChanged: (v) => setState(() => _query = v),
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            Expanded(
              child: sections.isEmpty
                  ? Center(
                      child: Text('No sound matches “$_query”',
                          style: theme.textTheme.bodyMedium),
                    )
                  : Scrollbar(
                      controller: _scroll,
                      child: ListView(
                        controller: _scroll,
                        primary: false,
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                        children: [
                          for (final (family, entries) in sections) ...[
                            SizedBox(
                              height: _headerHeight,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                                child: Text(
                                  family.toUpperCase(),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.primary,
                                    letterSpacing: 1.1,
                                  ),
                                ),
                              ),
                            ),
                            for (final (index, name) in entries)
                              SizedBox(
                                height: _rowHeight,
                                child: ListTile(
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10)),
                                  selected: index == widget.current,
                                  selectedTileColor:
                                      theme.colorScheme.secondaryContainer,
                                  leading: SizedBox(
                                    width: 32,
                                    child: Text('$index',
                                        textAlign: TextAlign.right,
                                        style: theme.textTheme.labelMedium?.copyWith(
                                            color: theme
                                                .colorScheme.onSurfaceVariant)),
                                  ),
                                  title: Text(name),
                                  trailing: index == widget.current
                                      ? const Icon(Icons.check)
                                      : null,
                                  onTap: () => Navigator.pop(context, index),
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
