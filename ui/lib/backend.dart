import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// One entry from the backend's inventory listing.
class NamedItem {
  const NamedItem({required this.id, required this.label, this.detail, this.isDefault = false});

  final String id;
  final String label;
  final String? detail;
  final bool isDefault;
}

/// Everything the backend knows about the machine, refreshed on demand.
class Inventory {
  const Inventory({
    this.gamepads = const [],
    this.destinations = const [],
    this.sources = const [],
    this.sinks = const [],
    this.programs = const [],
    this.families = const [],
    this.micAvailable = false,
  });

  final List<NamedItem> gamepads;
  final List<NamedItem> destinations;
  final List<NamedItem> sources;
  final List<NamedItem> sinks;
  final List<String> programs;
  final List<String> families;
  final bool micAvailable;

  factory Inventory.fromJson(Map<String, dynamic> j) {
    List<NamedItem> pads = [
      for (final g in (j['gamepads'] as List? ?? []))
        NamedItem(
          id: g['path'] as String,
          label: g['name'] as String,
          detail: (g['siblings'] as List?)?.isEmpty ?? true
              ? g['path'] as String
              : '${g['path']}  ·  ${(g['siblings'] as List).length} extra input(s)',
        ),
    ];
    List<NamedItem> dests = [
      for (final d in (j['destinations'] as List? ?? []))
        NamedItem(id: d['client'] as String, label: d['client'] as String, detail: d['port'] as String?),
    ];
    List<NamedItem> audio(String key) => [
          for (final s in (j[key] as List? ?? []))
            NamedItem(
              id: s['name'] as String,
              label: s['description'] as String,
              detail: s['name'] as String,
              isDefault: s['default'] as bool? ?? false,
            ),
        ];
    return Inventory(
      gamepads: pads,
      destinations: dests,
      sources: audio('sources'),
      sinks: audio('sinks'),
      programs: [for (final p in (j['programs'] as List? ?? [])) p as String],
      families: [for (final f in (j['families'] as List? ?? [])) f as String],
      micAvailable: j['mic_available'] as bool? ?? false,
    );
  }
}

/// Mirror of the engine's state.
class EngineState {
  const EngineState({
    this.running = false,
    this.mode = 'drums',
    this.channel = 10,
    this.program = 0,
    this.device,
    this.deviceName,
    this.extraDevices = const [],
    this.destination,
    this.micEnabled = false,
    this.micRunning = false,
    this.micSource,
    this.micAvailable = false,
    this.bend = 0,
  });

  final bool running;
  final String mode;
  final int channel;
  final int program;
  final String? device;
  final String? deviceName;
  final List<String> extraDevices;
  final String? destination;
  final bool micEnabled;
  final bool micRunning;
  final String? micSource;
  final bool micAvailable;
  final double bend;

  bool get isMelodic => mode == 'melodic';

  factory EngineState.fromJson(Map<String, dynamic> j) => EngineState(
        running: j['running'] as bool? ?? false,
        mode: j['mode'] as String? ?? 'drums',
        channel: j['channel'] as int? ?? 10,
        program: j['program'] as int? ?? 0,
        device: j['device'] as String?,
        deviceName: j['device_name'] as String?,
        extraDevices: [for (final d in (j['extra_devices'] as List? ?? [])) d as String],
        destination: j['destination'] as String?,
        micEnabled: j['mic_enabled'] as bool? ?? false,
        micRunning: j['mic_running'] as bool? ?? false,
        micSource: j['mic_source'] as String?,
        micAvailable: j['mic_available'] as bool? ?? false,
        bend: (j['bend'] as num? ?? 0).toDouble(),
      );
}

/// Talks to `gamepad-midi --serve` over its stdin/stdout JSON-line protocol.
class Backend extends ChangeNotifier {
  Backend({List<String>? command}) : _command = command ?? _defaultCommand();

  final List<String> _command;
  Process? _proc;

  Inventory inventory = const Inventory();
  EngineState state = const EngineState();
  String? error;
  bool connecting = false;

  /// Notes currently sounding, newest last - drives the activity strip.
  final List<int> activeNotes = [];
  double bend = 0;
  double micLevel = 1;

  /// Where the backend lives: installed first, then a sibling dev checkout.
  ///
  /// Checks paths relative to the executable as well as the working directory,
  /// so the app finds the checkout however it was launched.
  static final Directory? _devBackend = _findDevBackend();

  static Directory? _findDevBackend() {
    final bases = <String>[
      Directory.current.path,
      File(Platform.resolvedExecutable).parent.path,
    ];
    for (final base in bases) {
      var dir = Directory(base);
      // Walk up a few levels: the release bundle sits deep under ui/build/.
      for (var depth = 0; depth < 6; depth++) {
        final candidate = Directory('${dir.path}/backend/gamepad_midi');
        if (candidate.existsSync()) return candidate.parent;
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    }
    return null;
  }

  static List<String> _defaultCommand() {
    for (final candidate in ['/usr/bin/gamepad-midi', '/usr/local/bin/gamepad-midi']) {
      if (File(candidate).existsSync()) return [candidate, '--serve'];
    }
    if (_devBackend != null) return ['python3', '-m', 'gamepad_midi', '--serve'];
    return ['gamepad-midi', '--serve'];
  }

  Future<void> connect() async {
    if (_proc != null) return;
    connecting = true;
    error = null;
    notifyListeners();

    try {
      _proc = await Process.start(
        _command.first,
        _command.sublist(1),
        workingDirectory: _devBackend?.path,
      );
    } on ProcessException catch (e) {
      connecting = false;
      error = 'Could not launch the gamepad-midi backend. '
          'Install the package, or run the app from the source checkout. '
          '(${e.message})';
      notifyListeners();
      return;
    }

    _proc!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
          _onLine,
          onDone: _onExit,
        );
    _proc!.stderr.transform(utf8.decoder).listen((chunk) {
      if (chunk.trim().isNotEmpty) debugPrint('backend: $chunk');
    });
    connecting = false;
    notifyListeners();
  }

  void _onExit() {
    _proc = null;
    state = const EngineState();
    activeNotes.clear();
    notifyListeners();
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    final Map<String, dynamic> msg;
    try {
      msg = json.decode(line) as Map<String, dynamic>;
    } on FormatException {
      return;
    }

    switch (msg['event'] as String?) {
      case 'inventory':
        inventory = Inventory.fromJson(msg);
      case 'state':
      case 'started':
      case 'stopped':
        state = EngineState.fromJson(msg);
        if (!state.running) activeNotes.clear();
      case 'note':
        final note = msg['note'] as int;
        if (msg['on'] as bool? ?? false) {
          activeNotes.add(note);
          if (activeNotes.length > 16) activeNotes.removeAt(0);
        } else {
          activeNotes.remove(note);
        }
      case 'bend':
        bend = (msg['value'] as num).toDouble();
      case 'mic_level':
        micLevel = (msg['value'] as num).toDouble();
      case 'error':
        error = msg['message'] as String?;
    }
    notifyListeners();
  }

  void _send(Map<String, dynamic> msg) {
    final proc = _proc;
    if (proc == null) return;
    proc.stdin.writeln(json.encode(msg));
  }

  void clearError() {
    error = null;
    notifyListeners();
  }

  void refresh() => _send({'cmd': 'list'});
  void start(String? devicePath) => _send({'cmd': 'start', 'device': devicePath});
  void stop() => _send({'cmd': 'stop'});
  void setMode(String mode) => _send({'cmd': 'set_mode', 'mode': mode});
  void setProgram(int program) => _send({'cmd': 'set_program', 'program': program});
  void connectTo(String? destination) => _send({'cmd': 'connect', 'destination': destination});

  void setMic({bool? enabled, String? source, String? sink}) => _send({
        'cmd': 'set_mic',
        if (enabled != null) 'enabled': enabled,
        if (source != null) 'source': source,
        if (sink != null) 'sink': sink,
      });

  @override
  void dispose() {
    _send({'cmd': 'quit'});
    _proc?.kill();
    super.dispose();
  }
}
