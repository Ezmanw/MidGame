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

/// One remappable control or action, as described by the backend schema.
class SchemaItem {
  const SchemaItem({required this.key, required this.label, this.detail});

  final String key;
  final String label;
  final String? detail;

  factory SchemaItem.fromJson(Map<String, dynamic> j) => SchemaItem(
        key: j['key'] as String,
        label: j['label'] as String,
        detail: j['detail'] as String?,
      );
}

/// What the bindings editor can offer.
class BindingSchema {
  const BindingSchema({
    this.buttons = const [],
    this.axes = const [],
    this.actions = const [],
    this.path = '',
  });

  final List<SchemaItem> buttons;
  final List<SchemaItem> axes;
  final List<SchemaItem> actions;
  final String path;

  factory BindingSchema.fromJson(Map<String, dynamic> j) {
    List<SchemaItem> items(String key) => [
          for (final i in (j[key] as List? ?? []))
            SchemaItem.fromJson(i as Map<String, dynamic>),
        ];
    return BindingSchema(
      buttons: items('buttons'),
      axes: items('axes'),
      actions: items('actions'),
      path: j['path'] as String? ?? '',
    );
  }
}

/// The stored configuration, as the backend last reported it.
class EngineConfig {
  const EngineConfig(this.raw);

  final Map<String, dynamic> raw;

  int? binding(String mode, String key) {
    final table = raw[mode];
    if (table is! Map) return null;
    final value = table[key];
    return value is int ? value : null;
  }

  List<String> actions(String axis) {
    final axes = raw['axes'];
    if (axes is! Map) return const [];
    final list = axes[axis];
    if (list is! List) return const [];
    return [for (final a in list) a as String];
  }

  bool hasAction(String axis, String action) => actions(axis).contains(action);

  bool inverted(String axis) {
    final inv = raw['invert'];
    return inv is Map && inv[axis] == true;
  }
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
    this.drumNotes = const {},
    this.schema = const BindingSchema(),
    this.micAvailable = false,
  });

  final List<NamedItem> gamepads;
  final List<NamedItem> destinations;
  final List<NamedItem> sources;
  final List<NamedItem> sinks;
  final List<String> programs;
  final List<String> families;
  final Map<String, String> drumNotes;
  final BindingSchema schema;
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
      drumNotes: {
        for (final e in (j['drum_notes'] as Map? ?? {}).entries)
          e.key as String: e.value as String,
      },
      schema: BindingSchema.fromJson(
          (j['schema'] as Map?)?.cast<String, dynamic>() ?? const {}),
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
    this.micMonitor = true,
    this.micPitchFollow = true,
    this.micShiftRange = 12,
    this.combineOutput = false,
    this.busSink,
    this.hasTouchpad = false,
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
  final bool micMonitor;
  final bool micPitchFollow;
  final int micShiftRange;
  final bool combineOutput;
  final String? busSink;
  final bool hasTouchpad;
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
        micMonitor: j['mic_monitor'] as bool? ?? true,
        micPitchFollow: j['mic_pitch_follow'] as bool? ?? true,
        micShiftRange: (j['mic_shift_range'] as num? ?? 12).round(),
        combineOutput: j['combine_output'] as bool? ?? false,
        busSink: j['bus_sink'] as String?,
        hasTouchpad: j['has_touchpad'] as bool? ?? false,
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
  EngineConfig config = const EngineConfig({});
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
      case 'config':
        final raw = msg['config'];
        if (raw is Map) config = EngineConfig(raw.cast<String, dynamic>());
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

  void setConfig(Map<String, dynamic> patch) =>
      _send({'cmd': 'set_config', 'config': patch});

  void resetConfig() => _send({'cmd': 'reset_config'});

  void setBinding(String mode, String key, int? note) =>
      setConfig({mode: {key: note}});

  void toggleAction(String axis, String action, bool on) {
    final next = [...config.actions(axis)];
    if (on) {
      if (!next.contains(action)) next.add(action);
    } else {
      next.remove(action);
    }
    setConfig({'axes': {axis: next}});
  }

  void setInvert(String axis, bool value) => setConfig({'invert': {axis: value}});

  void setMicOption({bool? monitor, bool? pitchFollow, int? shiftRange}) =>
      setConfig({
        'mic': {
          if (monitor != null) 'monitor': monitor,
          if (pitchFollow != null) 'pitch_follow': pitchFollow,
          if (shiftRange != null) 'shift_range': shiftRange,
        }
      });

  void setCombineOutput(bool value) =>
      setConfig({'output': {'combine': value}});

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
