import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// A named Material 3 seed colour. The scheme is generated from the seed, so
/// one value defines the whole palette in both light and dark.
class Palette {
  const Palette(this.name, this.seed);

  final String name;
  final Color seed;
}

const List<Palette> kPalettes = [
  Palette('Default', Color(0xFF6750A4)),
  Palette('Indigo', Color(0xFF3F51B5)),
  Palette('Ocean', Color(0xFF00658F)),
  Palette('Teal', Color(0xFF006A6A)),
  Palette('Forest', Color(0xFF386A20)),
  Palette('Lime', Color(0xFF6C7A00)),
  Palette('Amber', Color(0xFF7D5700)),
  Palette('Ember', Color(0xFF9A4521)),
  Palette('Crimson', Color(0xFFB3261E)),
  Palette('Rose', Color(0xFF9C4146)),
  Palette('Orchid', Color(0xFF8E4585)),
  Palette('Slate', Color(0xFF4A6069)),
];

/// Holds the chosen palette and light/dark preference, persisted to the
/// user's XDG config directory so it survives a restart.
class ThemeController extends ChangeNotifier {
  ThemeController() {
    _load();
  }

  Color _seed = kPalettes.first.seed;
  ThemeMode _mode = ThemeMode.system;

  Color get seed => _seed;
  ThemeMode get mode => _mode;

  String get paletteName => kPalettes
      .firstWhere((p) => p.seed.toARGB32() == _seed.toARGB32(),
          orElse: () => const Palette('Custom', Color(0xFF6750A4)))
      .name;

  void setSeed(Color value) {
    if (value.toARGB32() == _seed.toARGB32()) return;
    _seed = value;
    notifyListeners();
    _save();
  }

  void setMode(ThemeMode value) {
    if (value == _mode) return;
    _mode = value;
    notifyListeners();
    _save();
  }

  // --------------------------------------------------------------- storage
  static File _settingsFile() {
    final home = Platform.environment['HOME'] ?? '.';
    final base = Platform.environment['XDG_CONFIG_HOME'] ?? '$home/.config';
    return File('$base/gamepad-midi/ui.json');
  }

  void _load() {
    try {
      final file = _settingsFile();
      if (!file.existsSync()) return;
      final data = json.decode(file.readAsStringSync()) as Map<String, dynamic>;
      final seed = data['seed'];
      if (seed is int) _seed = Color(seed);
      final mode = data['mode'];
      if (mode is String) {
        _mode = ThemeMode.values.firstWhere(
          (m) => m.name == mode,
          orElse: () => ThemeMode.system,
        );
      }
      notifyListeners();
    } on Exception {
      // A corrupt or unreadable settings file just means defaults.
    }
  }

  void _save() {
    try {
      final file = _settingsFile();
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
          json.encode({'seed': _seed.toARGB32(), 'mode': _mode.name}));
    } on Exception {
      // Not being able to persist the theme should never break the app.
    }
  }
}

/// Palette and light/dark picker.
Future<void> showPalettePicker(BuildContext context, ThemeController controller) {
  return showDialog<void>(
    context: context,
    builder: (_) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) => _PaletteDialog(controller: controller),
    ),
  );
}

class _PaletteDialog extends StatelessWidget {
  const _PaletteDialog({required this.controller});

  final ThemeController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      icon: const Icon(Icons.palette_outlined),
      title: const Text('Appearance'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.light,
                  label: Text('Light'),
                  icon: Icon(Icons.light_mode_outlined),
                ),
                ButtonSegment(
                  value: ThemeMode.system,
                  label: Text('System'),
                  icon: Icon(Icons.brightness_auto_outlined),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  label: Text('Dark'),
                  icon: Icon(Icons.dark_mode_outlined),
                ),
              ],
              selected: {controller.mode},
              onSelectionChanged: (s) => controller.setMode(s.first),
            ),
            const SizedBox(height: 20),
            Text('Colour', style: theme.textTheme.labelLarge),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final palette in kPalettes)
                  _Swatch(
                    palette: palette,
                    selected: palette.seed.toARGB32() == controller.seed.toARGB32(),
                    onTap: () => controller.setSeed(palette.seed),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.palette, required this.selected, required this.onTap});

  final Palette palette;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Show the swatch as the scheme it will actually produce, not the raw seed.
    final scheme = ColorScheme.fromSeed(
      seedColor: palette.seed,
      brightness: theme.brightness,
    );
    return Tooltip(
      message: palette.name,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 76,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? scheme.primary : theme.colorScheme.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration:
                        BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                palette.name,
                style: theme.textTheme.labelSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
