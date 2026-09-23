import 'package:flutter/material.dart';

import 'backend.dart';
import 'widgets/cards.dart';
import 'theme.dart';
import 'widgets/program_picker.dart';

void main() {
  runApp(const GamepadMidiApp());
}

class GamepadMidiApp extends StatefulWidget {
  const GamepadMidiApp({super.key});

  @override
  State<GamepadMidiApp> createState() => _GamepadMidiAppState();
}

class _GamepadMidiAppState extends State<GamepadMidiApp> {
  final Backend backend = Backend();
  final ThemeController themeController = ThemeController();

  @override
  void initState() {
    super.initState();
    backend.connect();
  }

  @override
  void dispose() {
    backend.dispose();
    themeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: themeController,
      builder: (context, _) => MaterialApp(
        title: 'Gamepad MIDI',
        debugShowCheckedModeBanner: false,
        themeMode: themeController.mode,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: themeController.seed),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
              seedColor: themeController.seed, brightness: Brightness.dark),
          useMaterial3: true,
        ),
        home: HomePage(backend: backend, themeController: themeController),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.backend, required this.themeController});

  final Backend backend;
  final ThemeController themeController;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Backend get backend => widget.backend;

  String? _selectedPad;
  String? _selectedDestination;
  String? _selectedSource;

  @override
  void initState() {
    super.initState();
    backend.addListener(_onBackendChange);
  }

  @override
  void dispose() {
    backend.removeListener(_onBackendChange);
    super.dispose();
  }

  void _onBackendChange() {
    final error = backend.error;
    if (error != null && mounted) {
      backend.clearError();
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          content: Text(error),
          behavior: SnackBarBehavior.floating,
          showCloseIcon: true,
        ));
    }
    setState(() {});
  }

  // Fall back to the first item / the system default when nothing is chosen yet.
  String? get _pad => _selectedPad ?? backend.state.device ??
      (backend.inventory.gamepads.isNotEmpty ? backend.inventory.gamepads.first.id : null);

  String? get _destination => _selectedDestination ?? backend.state.destination;

  String? get _source {
    if (_selectedSource != null) return _selectedSource;
    if (backend.state.micSource != null) return backend.state.micSource;
    for (final s in backend.inventory.sources) {
      if (s.isDefault) return s.id;
    }
    return backend.inventory.sources.isNotEmpty ? backend.inventory.sources.first.id : null;
  }

  Future<void> _pickProgram() async {
    final chosen = await showProgramPicker(
      context,
      programs: backend.inventory.programs,
      families: backend.inventory.families,
      current: backend.state.program,
    );
    if (chosen != null) backend.setProgram(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = backend.state;
    final inv = backend.inventory;
    final noPad = inv.gamepads.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gamepad MIDI'),
        actions: [
          IconButton(
            onPressed: () => showPalettePicker(context, widget.themeController),
            icon: const Icon(Icons.palette_outlined),
            tooltip: 'Appearance',
          ),
          IconButton(
            onPressed: backend.refresh,
            icon: const Icon(Icons.refresh),
            tooltip: 'Rescan devices',
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: noPad
            ? null
            : () => state.running ? backend.stop() : backend.start(_pad),
        icon: Icon(state.running ? Icons.stop_rounded : Icons.play_arrow_rounded),
        label: Text(state.running ? 'Stop' : 'Start playing'),
        backgroundColor: state.running ? theme.colorScheme.errorContainer : null,
        foregroundColor: state.running ? theme.colorScheme.onErrorContainer : null,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              StatusBanner(state: state, noPad: noPad),
              const SizedBox(height: 16),
              ControllerCard(
                gamepads: inv.gamepads,
                selected: _pad,
                locked: state.running,
                onChanged: (v) => setState(() => _selectedPad = v),
              ),
              const SizedBox(height: 12),
              OutputCard(
                destinations: inv.destinations,
                selected: _destination,
                onChanged: (v) {
                  setState(() => _selectedDestination = v);
                  backend.connectTo(v);
                },
              ),
              const SizedBox(height: 12),
              SoundCard(
                state: state,
                programName: state.program < inv.programs.length
                    ? inv.programs[state.program]
                    : 'Program ${state.program}',
                onModeChanged: backend.setMode,
                onPickProgram: _pickProgram,
              ),
              const SizedBox(height: 12),
              MicrophoneCard(
                state: state,
                sources: inv.sources,
                selectedSource: _source,
                available: inv.micAvailable,
                onToggle: (on) => backend.setMic(enabled: on, source: _source),
                onSourceChanged: (v) {
                  setState(() => _selectedSource = v);
                  backend.setMic(source: v);
                },
              ),
              const SizedBox(height: 12),
              ActivityCard(
                running: state.running,
                notes: backend.activeNotes,
                bend: backend.bend,
                micLevel: backend.micLevel,
                micOn: state.micRunning,
                isMelodic: state.isMelodic,
              ),
              const SizedBox(height: 12),
              const MappingCard(),
            ],
          ),
        ),
      ),
    );
  }
}
