import 'package:flutter/material.dart';

import '../backend.dart';

/// Editor for what every button, stick, trigger and the touchpad do.
class BindingsPage extends StatefulWidget {
  const BindingsPage({super.key, required this.backend});

  final Backend backend;

  @override
  State<BindingsPage> createState() => _BindingsPageState();
}

class _BindingsPageState extends State<BindingsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  Backend get backend => widget.backend;

  @override
  void initState() {
    super.initState();
    backend.addListener(_refresh);
  }

  @override
  void dispose() {
    backend.removeListener(_refresh);
    _tabs.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.restart_alt),
        title: const Text('Reset all bindings?'),
        content: const Text(
            'Every button, stick and touchpad assignment goes back to the '
            'defaults. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reset')),
        ],
      ),
    );
    if (ok ?? false) backend.resetConfig();
  }

  @override
  Widget build(BuildContext context) {
    final schema = backend.inventory.schema;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Controls'),
        actions: [
          IconButton(
            onPressed: _confirmReset,
            icon: const Icon(Icons.restart_alt),
            tooltip: 'Reset to defaults',
          ),
          const SizedBox(width: 8),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Drum kit'),
            Tab(text: 'Instrument'),
            Tab(text: 'Sticks & touchpad'),
          ],
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: TabBarView(
            controller: _tabs,
            children: [
              _ButtonList(backend: backend, mode: 'drums', schema: schema),
              _ButtonList(backend: backend, mode: 'melodic', schema: schema),
              _AxisList(backend: backend, schema: schema),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- buttons
class _ButtonList extends StatelessWidget {
  const _ButtonList({
    required this.backend,
    required this.mode,
    required this.schema,
  });

  final Backend backend;
  final String mode;
  final BindingSchema schema;

  bool get isDrums => mode == 'drums';

  String _noteLabel(int? note) {
    if (note == null) return 'Not assigned';
    if (isDrums) {
      final name = backend.inventory.drumNotes['$note'];
      return name == null ? 'Note $note' : '$name  ·  $note';
    }
    return '${noteName(note)}  ·  $note';
  }

  Future<void> _edit(BuildContext context, String key, String label) async {
    final current = backend.config.binding(mode, key);
    final chosen = await showDialog<int?>(
      context: context,
      builder: (_) => _NotePicker(
        title: label,
        current: current,
        drums: isDrums,
        drumNotes: backend.inventory.drumNotes,
      ),
    );
    if (chosen == null) return;
    backend.setBinding(mode, key, chosen == -1 ? null : chosen);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8, left: 4),
          child: Text(
            isDrums
                ? 'Buttons play the General MIDI percussion kit on channel 10.'
                : 'Buttons play notes on channel 1, using the instrument you picked.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        for (final button in schema.buttons)
          Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              title: Text(button.label),
              subtitle: Text(_noteLabel(backend.config.binding(mode, button.key))),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () => _edit(context, button.key, button.label),
            ),
          ),
      ],
    );
  }
}

/// Note names using the common convention where middle C (note 60) is C4.
String noteName(int note) {
  const names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
  return '${names[note % 12]}${(note ~/ 12) - 1}';
}

class _NotePicker extends StatefulWidget {
  const _NotePicker({
    required this.title,
    required this.current,
    required this.drums,
    required this.drumNotes,
  });

  final String title;
  final int? current;
  final bool drums;
  final Map<String, String> drumNotes;

  @override
  State<_NotePicker> createState() => _NotePickerState();
}

class _NotePickerState extends State<_NotePicker> {
  late int _value = widget.current ?? (widget.drums ? 36 : 60);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Drums: only the keys GM actually defines. Melodic: the full range.
    final entries = widget.drums
        ? (widget.drumNotes.keys.map(int.parse).toList()..sort())
        : List<int>.generate(128, (i) => i);

    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 600),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
              child: Row(
                children: [
                  Expanded(child: Text(widget.title, style: theme.textTheme.titleLarge)),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            Expanded(
              child: RadioGroup<int>(
                groupValue: _value,
                onChanged: (v) => setState(() => _value = v ?? _value),
                child: ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, i) {
                    final note = entries[i];
                    final label = widget.drums
                        ? (widget.drumNotes['$note'] ?? 'Note $note')
                        : noteName(note);
                    return RadioListTile<int>(
                      value: note,
                      title: Text(label),
                      secondary: Text('$note', style: theme.textTheme.labelMedium),
                    );
                  },
                ),
              ),
            ),
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () => Navigator.pop(context, -1),
                    icon: const Icon(Icons.block),
                    label: const Text('Unassign'),
                  ),
                  const Spacer(),
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, _value),
                      child: const Text('Assign')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ axes
class _AxisList extends StatelessWidget {
  const _AxisList({required this.backend, required this.schema});

  final Backend backend;
  final BindingSchema schema;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8, left: 4),
          child: Text(
            'Each control can drive several things at once. The touchpad is '
            'only read on controllers that have one.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        for (final axis in schema.axes)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(axis.label, style: theme.textTheme.titleSmall),
                      ),
                      Tooltip(
                        message: 'Reverse direction',
                        child: IconButton(
                          isSelected: backend.config.inverted(axis.key),
                          icon: const Icon(Icons.swap_vert),
                          selectedIcon: Icon(Icons.swap_vert,
                              color: theme.colorScheme.primary),
                          onPressed: () => backend.setInvert(
                              axis.key, !backend.config.inverted(axis.key)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final action in schema.actions)
                        FilterChip(
                          label: Text(action.label),
                          tooltip: action.detail,
                          selected: backend.config.hasAction(axis.key, action.key),
                          onSelected: (on) =>
                              backend.toggleAction(axis.key, action.key, on),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
