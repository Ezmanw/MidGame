"""Gamepad -> MIDI engine, with an optional microphone path."""

import selectors
import subprocess
import threading
import time

from evdev import ecodes as E
import mido

from . import audio, config, devices, mapping
from .mapping import VELOCITY

PORT_NAME = "Gamepad MIDI"
BEND_RANGE_SEMITONES = 2.0     # what a synth typically does with a full bend


class Engine:
    """Owns the controller, the MIDI port and the mic chain.

    The evdev loop runs in its own thread and is the only writer of the
    note/bend state; the UI only calls the setters below.
    """

    def __init__(self, on_event=None):
        self.on_event = on_event or (lambda kind, data: None)
        self._thread = None
        self._stop = threading.Event()

        self.cfg = config.load()
        self.devices = []
        self.axes = {}
        self.roles = {}
        self.out = None
        self.mic = audio.MicChain()
        self.bus = audio.OutputBus()

        self.mode = "drums"
        self.channel = 9
        self.program = 0
        self.device_path = None
        self.destination = None
        self.mic_enabled = False
        self.mic_source = None
        self.mic_sink = None
        self.grab = True

        self._held = set()
        self._hat_state = {E.ABS_HAT0X: 0, E.ABS_HAT0Y: 0}
        self._bend = 0.0
        self._last_bend_sent = None
        self._last_cc = {}

    # ------------------------------------------------------------------ state
    def state(self):
        mic_cfg = self.cfg.get("mic", {})
        out_cfg = self.cfg.get("output", {})
        return {
            "running": self.running,
            "mode": self.mode,
            "channel": self.channel + 1,
            "program": self.program,
            "device": self.device_path,
            "device_name": self.devices[0].name if self.devices else None,
            "extra_devices": [d.name for d in self.devices[1:]],
            "destination": self.destination,
            "mic_enabled": self.mic_enabled,
            "mic_running": self.mic.running,
            "mic_source": self.mic_source,
            "mic_sink": self.mic_sink,
            "mic_available": audio.available(),
            "mic_monitor": bool(mic_cfg.get("monitor", True)),
            "mic_pitch_follow": bool(mic_cfg.get("pitch_follow", True)),
            "mic_shift_range": mic_cfg.get("shift_range", 12),
            "combine_output": bool(out_cfg.get("combine", False)),
            "bus_active": self.bus.active,
            "bus_sink": self.bus.sink_name if self.bus.active else None,
            "has_touchpad": any(k.startswith("touch_") for k in self.roles),
            "bend": round(self._bend, 3),
        }

    @property
    def running(self):
        return self._thread is not None and self._thread.is_alive()

    def _emit(self, kind, **data):
        try:
            self.on_event(kind, data)
        except Exception:                  # never let a UI error kill the loop
            pass

    # ------------------------------------------------------------------ config
    def get_config(self):
        return self.cfg

    def update_config(self, patch):
        """Merge a partial config from the UI, persist it, apply it live."""
        for section, value in (patch or {}).items():
            if isinstance(value, dict) and isinstance(self.cfg.get(section), dict):
                self.cfg[section].update(value)
            else:
                self.cfg[section] = value
        config.save(self.cfg)
        self._reapply()

    def reset_config(self):
        self.cfg = config.reset()
        self._reapply()

    def _reapply(self):
        """Push config changes into a running session."""
        if self.devices:
            self.axes, self.roles = mapping.build_axes(self.devices, self.cfg)
        self._apply_output_routing()
        if self.mic_enabled and self.mic.running:
            self._apply_mic_settings()
        self._emit("config", config=self.cfg)
        self._emit("state", **self.state())

    # ---------------------------------------------------------------- lifecycle
    def start(self, device_path=None):
        if self.running:
            return True, "already running"
        try:
            self.devices = devices.open_group(device_path or self.device_path)
        except OSError as exc:
            return False, f"could not open controller: {exc}"
        if not self.devices:
            return False, "no gamepad found"

        self.device_path = self.devices[0].path
        self.axes, self.roles = mapping.build_axes(self.devices, self.cfg)

        try:
            self.out = mido.open_output(PORT_NAME, virtual=True)
        except (OSError, IOError) as exc:
            self._close_devices()
            return False, f"could not open MIDI port: {exc}"

        self.reset_controllers()
        if self.mode == "melodic":
            self._send(mido.Message("program_change", program=self.program, channel=0))
        if self.destination:
            self.connect_to(self.destination)
        self._apply_output_routing()
        if self.mic_enabled:
            self._start_mic()

        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        self._emit("started", **self.state())
        return True, "started"

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2)
        self._thread = None
        self._all_notes_off()
        self.mic.stop()
        self.bus.teardown()
        if self.out:
            self.reset_controllers()
            self.out.close()
            self.out = None
        self._close_devices()
        self._emit("stopped", **self.state())

    def _close_devices(self):
        for d in self.devices:
            for call in (d.ungrab, d.close):
                try:
                    call()
                except OSError:
                    pass
        self.devices = []

    # -------------------------------------------------------------------- midi
    def _send(self, msg):
        if self.out:
            try:
                self.out.send(msg)
            except (OSError, IOError):
                pass

    def reset_controllers(self):
        """Clear anything a previous run left set (mod wheel, effects, bend)."""
        for ch in range(16):
            self._send(mido.Message("control_change", control=121, value=0, channel=ch))
            for cc in (1, 91, 93):
                self._send(mido.Message("control_change", control=cc, value=0, channel=ch))
            self._send(mido.Message("pitchwheel", pitch=0, channel=ch))
        self._last_cc.clear()

    def _all_notes_off(self):
        for note in list(self._held):
            self._send(mido.Message("note_off", note=note, velocity=0,
                                    channel=self.channel))
        self._held.clear()
        self._send(mido.Message("pitchwheel", pitch=0, channel=self.channel))

    def send_program(self, program):
        """Program change. GM synths ignore this on the drum channel."""
        self.program = max(0, min(127, int(program)))
        if self.mode == "melodic":
            self._send(mido.Message("program_change", program=self.program,
                                    channel=self.channel))
        self._emit("state", **self.state())

    def set_mode(self, mode):
        if mode not in ("drums", "melodic"):
            return
        self._all_notes_off()
        self.mode = mode
        self.channel = 9 if mode == "drums" else 0
        if mode == "melodic":
            self._send(mido.Message("program_change", program=self.program, channel=0))
        self._emit("state", **self.state())

    @staticmethod
    def _ports():
        try:
            return subprocess.run(["aconnect", "-l"], capture_output=True,
                                  text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            return ""

    @classmethod
    def _own_address(cls):
        cid = None
        for line in cls._ports().splitlines():
            if line.startswith("client "):
                cid = line.split(":", 1)[0].split()[1]
            elif cid and line.startswith(("    ", "\t")) and "'" in line:
                if line.lstrip().startswith("Connect"):
                    continue
                if line.split("'")[1].strip() == PORT_NAME:
                    return f"{cid}:{line.split()[0]}"
        return None

    @classmethod
    def list_destinations(cls):
        """ALSA sequencer ports we could play into."""
        out, client, cid = [], None, None
        for line in cls._ports().splitlines():
            if line.startswith("client "):
                cid = line.split(":", 1)[0].split()[1]
                client = line.split("'")[1].strip() if "'" in line else ""
            elif client and line.startswith(("    ", "\t")) and "'" in line:
                if line.lstrip().startswith("Connect"):
                    continue
                if client in ("System", PORT_NAME) or client.startswith("PipeWire-"):
                    continue
                out.append({"client": client, "port": line.split("'")[1].strip(),
                            "addr": f"{cid}:{line.split()[0]}"})
        return out

    def connect_to(self, destination):
        """Wire our virtual port to a destination, by numeric address.

        aconnect matches client names only, and several clients can share ours
        ("RtMidiOut Client"), so both ends are resolved to addresses first.
        """
        self.destination = destination or None
        if not destination:
            return False
        src = self._own_address()
        dst = next((d["addr"] for d in self.list_destinations()
                    if d["client"] == destination), None)
        if src is None or dst is None:
            self._emit("error", message=f"could not resolve MIDI ports for "
                                        f"'{destination}'")
            return False
        result = subprocess.run(["aconnect", src, dst], capture_output=True, text=True)
        if result.returncode != 0:
            detail = (result.stderr or "aconnect failed").strip()
            # Re-selecting the same destination is not worth an error toast.
            if "already subscribed" not in detail.lower():
                self._emit("error", message=detail)
        self._emit("state", **self.state())
        return result.returncode == 0

    # ------------------------------------------------------------------ output
    def _apply_output_routing(self):
        """Optionally collect the synth and the mic into one virtual output."""
        want = bool(self.cfg.get("output", {}).get("combine", False))
        if want and not self.bus.active:
            if not self.bus.setup(self.cfg.get("output", {}).get("monitor_sink")):
                self._emit("error", message="could not create the combined output")
                return
        elif not want and self.bus.active:
            self.bus.teardown()

        if self.bus.active:
            moved = self.bus.capture_streams(self.destination)
            self._emit("output", sink=self.bus.sink_name, moved=moved)

    # --------------------------------------------------------------------- mic
    def set_mic(self, enabled=None, source=None, sink=None):
        if source is not None:
            self.mic_source = source or None
        if sink is not None:
            self.mic_sink = sink or None
        if enabled is not None:
            self.mic_enabled = bool(enabled)

        self.mic.stop()
        if self.mic_enabled:
            self._start_mic()
        self._emit("state", **self.state())

    def _mic_target_sink(self):
        """Where the mic lands: the combined bus if there is one."""
        if self.bus.active:
            return self.bus.sink_name
        return self.mic_sink

    def _start_mic(self):
        if not self.mic.start(self.mic_source, self._mic_target_sink()):
            self._emit("error", message="microphone chain unavailable "
                                        "(needs pipewire and tap-plugins)")
            self.mic_enabled = False
            return
        time.sleep(0.4)          # let the node appear before the first write
        self._apply_mic_settings()

    def _apply_mic_settings(self):
        """Monitoring off simply mutes the mic, so there is no feedback path."""
        mic_cfg = self.cfg.get("mic", {})
        self.mic.set_level(1.0 if mic_cfg.get("monitor", True) else 0.0)
        if not mic_cfg.get("pitch_follow", True):
            self.mic.set_shift(0.0)

    # -------------------------------------------------------------- event loop
    def _note_on(self, note):
        self._send(mido.Message("note_on", note=note, velocity=VELOCITY,
                                channel=self.channel))
        self._held.add(note)
        self._emit("note", note=note, on=True)

    def _note_off(self, note):
        self._send(mido.Message("note_off", note=note, velocity=0,
                                channel=self.channel))
        self._held.discard(note)
        self._emit("note", note=note, on=False)

    def _axis_value(self, role):
        key = self.roles.get(role)
        ax = self.axes.get(key) if key else None
        return ax.value if ax else 0.0

    def _roles_with(self, action):
        return [r for r, actions in self.cfg.get("axes", {}).items()
                if action in (actions or [])]

    def _send_cc(self, cc, value01):
        value = max(0, min(127, round(value01 * 127)))
        if self._last_cc.get(cc) == value:
            return
        self._last_cc[cc] = value
        self._send(mido.Message("control_change", control=cc, value=value,
                                channel=self.channel))

    def _apply_actions(self, role):
        """Run every action bound to the axis that just moved."""
        actions = self.cfg.get("axes", {}).get(role) or []
        if not actions:
            return
        value = self._axis_value(role)
        mic_cfg = self.cfg.get("mic", {})

        for action in actions:
            if action == "pitch_bend":
                self._apply_bend()
            elif action == "mic_pitch":
                if (self.mic_enabled and self.mic.running
                        and mic_cfg.get("pitch_follow", True)):
                    span = float(mic_cfg.get("shift_range", 12))
                    self.mic.set_shift(value * span)
            elif action == "mic_level":
                if (self.mic_enabled and self.mic.running
                        and mic_cfg.get("monitor", True)):
                    # Centre is full level; pulling back fades out.
                    level = 1.0 if value >= 0 else 1.0 + value
                    self.mic.set_level(level)
                    self._emit("mic_level", value=round(level, 3))
            elif action in config.ACTION_CC:
                key = self.roles.get(role)
                ax = self.axes.get(key) if key else None
                unit = (value + 1) / 2 if (ax and ax.centred) else value
                self._send_cc(config.ACTION_CC[action], unit)

    def _apply_bend(self):
        """Whichever bend-bound axis is pushed furthest wins."""
        bend = 0.0
        for role in self._roles_with("pitch_bend"):
            value = self._axis_value(role)
            if abs(value) > abs(bend):
                bend = value
        if abs(bend - self._bend) <= 1e-3:
            return
        self._bend = bend
        pitch = max(-8192, min(8191, int(round(bend * 8191))))
        if pitch != self._last_bend_sent:
            self._last_bend_sent = pitch
            self._send(mido.Message("pitchwheel", pitch=pitch, channel=self.channel))
        self._emit("bend", value=round(bend, 3),
                   semitones=round(bend * BEND_RANGE_SEMITONES, 2))

    def _loop(self):
        sel = selectors.DefaultSelector()
        for d in self.devices:
            if self.grab:
                try:
                    d.grab()   # stop the DS4 touchpad driving the desktop mouse
                except OSError:
                    pass
            sel.register(d, selectors.EVENT_READ)

        try:
            while not self._stop.is_set():
                role_of = {v: k for k, v in self.roles.items()}
                buttons, hats = mapping.note_tables(self.cfg, self.mode)
                for key, _ in sel.select(timeout=0.2):
                    dev = key.fileobj
                    try:
                        events = list(dev.read())
                    except OSError:
                        self._emit("error", message="controller disconnected")
                        self._stop.set()
                        break
                    for ev in events:
                        self._handle(ev, dev, buttons, hats, role_of)
        finally:
            sel.close()

    def _handle(self, ev, dev, buttons, hats, role_of):
        if ev.type == E.EV_KEY:
            if ev.code in buttons:
                if ev.value == 1:
                    self._note_on(buttons[ev.code])
                elif ev.value == 0:
                    self._note_off(buttons[ev.code])
            elif ev.code == E.BTN_TOUCH and ev.value == 0:
                # Finger lifted: park whatever the touchpad was driving.
                for role in ("touch_x", "touch_y"):
                    key = self.roles.get(role)
                    if key and key in self.axes:
                        self.axes[key].value = 0.0
                        self._apply_actions(role)
            return

        if ev.type != E.EV_ABS:
            return

        if ev.code in self._hat_state:
            prev = self._hat_state[ev.code]
            if prev and (ev.code, prev) in hats:
                self._note_off(hats[(ev.code, prev)])
            if ev.value and (ev.code, ev.value) in hats:
                self._note_on(hats[(ev.code, ev.value)])
            self._hat_state[ev.code] = ev.value
            return

        ax = self.axes.get((dev.path, ev.code))
        if ax is None or not ax.update(ev.value):
            return
        role = role_of.get((dev.path, ev.code))
        if role:
            self._apply_actions(role)
