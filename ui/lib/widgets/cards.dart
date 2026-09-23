import 'package:flutter/material.dart';

import '../backend.dart';

/// Shared shell so every section reads the same: icon, title, then content.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleMedium),
                      if (subtitle != null)
                        Text(subtitle!,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _Dropdown extends StatelessWidget {
  const _Dropdown({
    required this.label,
    required this.items,
    required this.value,
    required this.onChanged,
    this.emptyHint = 'Nothing found',
    this.enabled = true,
  });

  final String label;
  final List<NamedItem> items;
  final String? value;
  final ValueChanged<String?>? onChanged;
  final String emptyHint;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return InputDecorator(
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        child: Text(emptyHint, style: Theme.of(context).textTheme.bodyMedium),
      );
    }
    final safeValue = items.any((i) => i.id == value) ? value : null;
    return DropdownButtonFormField<String>(
      initialValue: safeValue,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      onChanged: enabled ? onChanged : null,
      items: [
        for (final item in items)
          DropdownMenuItem(
            value: item.id,
            child: Text(
              item.isDefault ? '${item.label}  (default)' : item.label,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}

class StatusBanner extends StatelessWidget {
  const StatusBanner({super.key, required this.state, required this.noPad});

  final EngineState state;
  final bool noPad;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (IconData icon, String text, Color bg, Color fg) = switch ((noPad, state.running)) {
      (true, _) => (
          Icons.videogame_asset_off_outlined,
          'No controller detected — plug one in, then press Rescan.',
          theme.colorScheme.errorContainer,
          theme.colorScheme.onErrorContainer,
        ),
      (false, true) => (
          Icons.graphic_eq,
          'Playing as ${state.deviceName ?? 'controller'} '
              '· channel ${state.channel} · ${state.isMelodic ? 'melodic' : 'drums'}',
          theme.colorScheme.primaryContainer,
          theme.colorScheme.onPrimaryContainer,
        ),
      (false, false) => (
          Icons.pause_circle_outline,
          'Ready. Press Start playing.',
          theme.colorScheme.surfaceContainerHighest,
          theme.colorScheme.onSurfaceVariant,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(icon, color: fg, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: fg))),
        ],
      ),
    );
  }
}

class ControllerCard extends StatelessWidget {
  const ControllerCard({
    super.key,
    required this.gamepads,
    required this.selected,
    required this.locked,
    required this.onChanged,
  });

  final List<NamedItem> gamepads;
  final String? selected;
  final bool locked;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      icon: Icons.sports_esports_outlined,
      title: 'Controller',
      subtitle: locked ? 'Stop playing to switch controller' : null,
      child: _Dropdown(
        label: 'Gamepad',
        items: gamepads,
        value: selected,
        enabled: !locked,
        emptyHint: 'No gamepad detected',
        onChanged: onChanged,
      ),
    );
  }
}

class OutputCard extends StatelessWidget {
  const OutputCard({
    super.key,
    required this.state,
    required this.destinations,
    required this.selected,
    required this.onChanged,
    required this.onCombineChanged,
  });

  final EngineState state;
  final List<NamedItem> destinations;
  final String? selected;
  final ValueChanged<String?> onChanged;
  final ValueChanged<bool> onCombineChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      icon: Icons.piano_outlined,
      title: 'MIDI output',
      subtitle: 'Where the notes go. Start a synth first if the list is empty.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Dropdown(
            label: 'Send to',
            items: destinations,
            value: selected,
            emptyHint: 'No synth or DAW listening',
            onChanged: onChanged,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: state.combineOutput,
            onChanged: onCombineChanged,
            title: const Text('One combined output'),
            subtitle: Text(
              state.busSink == null
                  ? 'Collect the synth and the microphone into a single audio '
                    'device, handy for recording or streaming'
                  : 'Synth and microphone are going to "MidGame Output". '
                    'Pick that device in OBS or your recorder',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class SoundCard extends StatelessWidget {
  const SoundCard({
    super.key,
    required this.state,
    required this.programName,
    required this.onModeChanged,
    required this.onPickProgram,
  });

  final EngineState state;
  final String programName;
  final ValueChanged<String> onModeChanged;
  final VoidCallback onPickProgram;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      icon: Icons.music_note_outlined,
      title: 'Sound',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'drums',
                label: Text('Drum kit'),
                icon: Icon(Icons.album_outlined),
              ),
              ButtonSegment(
                value: 'melodic',
                label: Text('Instrument'),
                icon: Icon(Icons.queue_music_outlined),
              ),
            ],
            selected: {state.mode},
            onSelectionChanged: (s) => onModeChanged(s.first),
          ),
          const SizedBox(height: 12),
          if (state.isMelodic)
            ListTile(
              contentPadding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
              leading: Padding(
                padding: const EdgeInsets.only(left: 12),
                child: CircleAvatar(
                  backgroundColor: theme.colorScheme.secondaryContainer,
                  child: Text('${state.program}',
                      style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSecondaryContainer)),
                ),
              ),
              title: Text(programName),
              subtitle: const Text('General MIDI program'),
              trailing: const Padding(
                padding: EdgeInsets.only(right: 12),
                child: Icon(Icons.chevron_right),
              ),
              onTap: onPickProgram,
            )
          else
            Text(
              'Buttons are mapped to the General MIDI percussion kit on '
              'channel 10. Instrument choice does not apply to drums.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

class MicrophoneCard extends StatelessWidget {
  const MicrophoneCard({
    super.key,
    required this.state,
    required this.sources,
    required this.selectedSource,
    required this.available,
    required this.onToggle,
    required this.onSourceChanged,
    required this.onMonitorChanged,
    required this.onPitchFollowChanged,
  });

  final EngineState state;
  final List<NamedItem> sources;
  final String? selectedSource;
  final bool available;
  final ValueChanged<bool> onToggle;
  final ValueChanged<String?> onSourceChanged;
  final ValueChanged<bool> onMonitorChanged;
  final ValueChanged<bool> onPitchFollowChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      icon: state.micEnabled ? Icons.mic_none_outlined : Icons.mic_off_outlined,
      title: 'Microphone',
      subtitle: available
          ? 'Mix your voice in and bend it with the left stick'
          : 'Unavailable — needs PipeWire and the tap-plugins package',
      trailing: Switch(
        value: state.micEnabled,
        onChanged: available ? onToggle : null,
      ),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 180),
        alignment: Alignment.topCenter,
        child: state.micEnabled
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Dropdown(
                    label: 'Input device',
                    items: sources,
                    value: selectedSource,
                    emptyHint: 'No microphone found',
                    onChanged: onSourceChanged,
                  ),
                  const SizedBox(height: 4),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: state.micMonitor,
                    onChanged: onMonitorChanged,
                    title: const Text('Hear myself'),
                    subtitle: const Text(
                        'Off mutes the mic through your speakers, which stops '
                        'feedback howling when they are close by'),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: state.micPitchFollow,
                    onChanged: onPitchFollowChanged,
                    title: const Text('Stick bends my voice'),
                    subtitle: Text(
                        'Off leaves the mic at its natural pitch. On, a stick '
                        'shifts it up to ${state.micShiftRange} semitones'),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.info_outline,
                          size: 16, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'At rest the mic passes straight through with no added '
                          'latency. Pitch shifting only engages once the stick '
                          'leaves centre.',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ],
              )
            : const SizedBox(width: double.infinity),
      ),
    );
  }
}

class ActivityCard extends StatelessWidget {
  const ActivityCard({
    super.key,
    required this.running,
    required this.notes,
    required this.bend,
    required this.micLevel,
    required this.micOn,
    required this.isMelodic,
  });

  final bool running;
  final List<int> notes;
  final double bend;
  final double micLevel;
  final bool micOn;
  final bool isMelodic;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      icon: Icons.equalizer_outlined,
      title: 'Live',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 36,
            child: notes.isEmpty
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      running ? 'Press a button on the controller…' : 'Not running',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  )
                : ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final note in notes)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Chip(
                            visualDensity: VisualDensity.compact,
                            label: Text('$note'),
                            backgroundColor: theme.colorScheme.primaryContainer,
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 8),
          _Meter(
            label: 'Pitch bend',
            icon: Icons.unfold_more,
            value: (bend + 1) / 2,
            centred: true,
            readout: '${bend >= 0 ? '+' : ''}${(bend * 2).toStringAsFixed(1)} st',
          ),
          if (micOn) ...[
            const SizedBox(height: 8),
            _Meter(
              label: 'Mic level',
              icon: Icons.volume_up_outlined,
              value: micLevel,
              readout: '${(micLevel * 100).round()}%',
            ),
          ],
        ],
      ),
    );
  }
}

class _Meter extends StatelessWidget {
  const _Meter({
    required this.label,
    required this.icon,
    required this.value,
    required this.readout,
    this.centred = false,
  });

  final String label;
  final IconData icon;
  final double value;
  final String readout;
  final bool centred;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        SizedBox(
          width: 78,
          child: Text(label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: value.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ),
        SizedBox(
          width: 60,
          child: Text(readout,
              textAlign: TextAlign.right, style: theme.textTheme.labelSmall),
        ),
      ],
    );
  }
}
