"""Gamepad -> MIDI engine, with an optional microphone path."""

import selectors
import subprocess
import threading
import time

import evdev
from evdev import ecodes as E
import mido

from . import audio, devices, mapping
from .mapping import Axis, VELOCITY

PORT_NAME = "Gamepad MIDI"
BEND_RANGE_SEMITONES = 2.0     # what the synth does with a full-scale bend
MIC_SHIFT_SEMITONES = 12.0     # full stick deflection = one octave on the mic


class Engine:
    """Owns the controller, the MIDI port and the mic chain.

    Thread-safe for the small set of setters the UI calls; the evdev loop runs
    in its own thread and is the only writer of the note/bend state.
    """

    def __init__(self, on_event=None):
        self.on_event = on_event or (lambda kind, data: None)
        self._lock = threading.Lock()
        self._thread = None
        self._stop = threading.Event()

        self.devices = []
        self.axes = {}
        self.roles = {}
        self.out = None
        self.mic = audio.MicChain()

        self.mode = "drums"           # "drums" | "melodic"
        self.channel = 9
        self.program = 0
        self.device_path = None
        self.destination = None       # ALSA seq port name to auto-connect to
        self.mic_enabled = False
        self.mic_source = None
        self.mic_sink = None
        self.grab = True

        self._held = set()
        self._hat_state = {E.ABS_HAT0X: 0, E.ABS_HAT0Y: 0}
        self._bend = 0.0
        self._last_bend_sent = None

    # ------------------------------------------------------------------ state
    def state(self):
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
            "bend": round(self._bend, 3),
        }

    @property
    def running(self):
        return self._thread is not None and self._thread.is_alive()

    def _emit(self, kind, **data):
        try:
            self.on_event(kind, data)
        except Exception:                      # never let a UI error kill the loop
            pass

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
        self.roles = {}
        self.axes = mapping.classify_axes(self.devices, self.roles)

        try:
            self.out = mido.open_output(PORT_NAME, virtual=True)
        except (OSError, IOError) as exc:
            self._close_devices()
            return False, f"could not open MIDI port: {exc}"

        self.reset_controllers()
        self.send_program(self.program)
        if self.destination:
            self.connect_to(self.destination)
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
        if self.out:
            self.reset_controllers()
            self.out.close()
            self.out = None
        self._close_devices()
        self._emit("stopped", **self.state())

    def _close_devices(self):
        for d in self.devices:
            try:
                d.ungrab()
            except OSError:
                pass
            try:
                d.close()
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

    def _all_notes_off(self):
        for note in list(self._held):
            self._send(mido.Message("note_off", note=note, velocity=0, channel=self.channel))
        self._held.clear()
        self._send(mido.Message("pitchwheel", pitch=0, channel=self.channel))

    def send_program(self, program):
        """Program change. Ignored by GM synths on the drum channel."""
        with self._lock:
            self.program = max(0, min(127, int(program)))
        if self.mode == "melodic":
            self._send(mido.Message("program_change", program=self.program,
                                    channel=self.channel))
        self._emit("state", **self.state())

    def set_mode(self, mode):
        if mode not in ("drums", "melodic"):
            return
        self._all_notes_off()
        with self._lock:
            self.mode = mode
            self.channel = 9 if mode == "drums" else 0
        if mode == "melodic":
            self._send(mido.Message("program_change", program=self.program, channel=0))
        self._emit("state", **self.state())

    @staticmethod
    def _own_address():
        """Numeric ALSA address of our own virtual output port."""
        try:
            raw = subprocess.run(["aconnect", "-l"], capture_output=True,
                                 text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            return None
        cid = None
        for line in raw.splitlines():
            if line.startswith("client "):
                cid = line.split(":", 1)[0].split()[1]
            elif cid and line.startswith(("    ", "\t")) and "'" in line:
                if line.lstrip().startswith("Connect"):
                    continue
                if line.split("'")[1].strip() == PORT_NAME:
                    return f"{cid}:{line.split()[0]}"
        return None

    def connect_to(self, destination):
        """Wire our virtual port to an ALSA sequencer port.

        `destination` is a client name as listed by list_destinations(); we
        resolve both ends to numeric addresses because aconnect matches client
        names only, and several clients can share ours ("RtMidiOut Client").
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
        ok = result.returncode == 0
        if not ok:
            self._emit("error", message=(result.stderr or "aconnect failed").strip())
        self._emit("state", **self.state())
        return ok

    @staticmethod
    def list_destinations():
        """ALSA seq input ports we could play into."""
        try:
            raw = subprocess.run(["aconnect", "-l"], capture_output=True,
                                 text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            return []
        out, client, cid = [], None, None
        for line in raw.splitlines():
            if line.startswith("client "):
                cid = line.split(":", 1)[0].split()[1]
                client = line.split("'")[1].strip() if "'" in line else ""
            elif client and line.startswith(("    ", "\t")) and "'" in line:
                if line.lstrip().startswith("Connect"):
                    continue
                port = line.split("'")[1].strip()
                if client in ("System", PORT_NAME) or client.startswith("PipeWire-"):
                    continue
                out.append({"client": client, "port": port,
                            "addr": f"{cid}:{line.split()[0]}"})
        return out

    # --------------------------------------------------------------------- mic
    def set_mic(self, enabled=None, source=None, sink=None):
        if source is not None:
            self.mic_source = source or None
        if sink is not None:
            self.mic_sink = sink or None
        if enabled is not None:
            self.mic_enabled = bool(enabled)

        if self.mic_enabled:
            self.mic.stop()
            self._start_mic()
        else:
            self.mic.stop()
        self._emit("state", **self.state())

    def _start_mic(self):
        if not self.mic.start(self.mic_source, self.mic_sink):
            self._emit("error", message="microphone chain unavailable "
                                        "(needs pipewire and tap-plugins)")
            self.mic_enabled = False
            return
        # Give the node a moment to appear before the first parameter write.
        time.sleep(0.4)
        self.mic.set_level(1.0)
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

    def _apply_bend(self):
        """Both sticks bend; the larger deflection wins."""
        left = self.axes.get((self.device_path, self.roles.get("left_y")))
        right = self.axes.get((self.device_path, self.roles.get("right_y")))
        lv = left.value if left else 0.0
        rv = right.value if right else 0.0
        bend = lv if abs(lv) >= abs(rv) else rv

        if abs(bend - self._bend) > 1e-3:
            self._bend = bend
            pitch = max(-8192, min(8191, int(round(bend * 8191))))
            if pitch != self._last_bend_sent:
                self._last_bend_sent = pitch
                self._send(mido.Message("pitchwheel", pitch=pitch, channel=self.channel))
            self._emit("bend", value=round(bend, 3),
                       semitones=round(bend * BEND_RANGE_SEMITONES, 2))

        # Only the left stick drives the microphone.
        if self.mic_enabled and self.mic.running:
            self.mic.set_shift(lv * MIC_SHIFT_SEMITONES)

    def _apply_mic_level(self):
        if not (self.mic_enabled and self.mic.running):
            return
        ax = self.axes.get((self.device_path, self.roles.get("left_x")))
        if ax is None:
            return
        # Stick centre = full level, pull left to fade out, push right stays full.
        level = 1.0 if ax.value >= 0 else 1.0 + ax.value
        self.mic.set_level(level)
        self._emit("mic_level", value=round(level, 3))

    def _loop(self):
        buttons, hat = mapping.tables(self.mode)
        sel = selectors.DefaultSelector()
        for d in self.devices:
            if self.grab:
                try:
                    d.grab()      # stop the DS4 touchpad driving the desktop mouse
                except OSError:
                    pass
            sel.register(d, selectors.EVENT_READ)

        try:
            while not self._stop.is_set():
                buttons, hat = mapping.tables(self.mode)
                for key, _ in sel.select(timeout=0.2):
                    dev = key.fileobj
                    try:
                        events = list(dev.read())
                    except OSError:
                        self._emit("error", message="controller disconnected")
                        self._stop.set()
                        break
                    for ev in events:
                        self._handle(ev, dev, buttons, hat)
        finally:
            sel.close()

    def _handle(self, ev, dev, buttons, hat):
        if ev.type == E.EV_KEY and ev.code in buttons:
            if ev.value == 1:
                self._note_on(buttons[ev.code])
            elif ev.value == 0:
                self._note_off(buttons[ev.code])
            return

        if ev.type != E.EV_ABS:
            return

        if ev.code in self._hat_state:
            prev = self._hat_state[ev.code]
            if prev and (ev.code, prev) in hat:
                self._note_off(hat[(ev.code, prev)])
            if ev.value and (ev.code, ev.value) in hat:
                self._note_on(hat[(ev.code, ev.value)])
            self._hat_state[ev.code] = ev.value
            return

        ax = self.axes.get((dev.path, ev.code))
        if ax is None or not ax.update(ev.value):
            return

        if dev.path == self.device_path:
            if ev.code in (self.roles.get("left_y"), self.roles.get("right_y")):
                self._apply_bend()
            elif ev.code == self.roles.get("left_x"):
                self._apply_mic_level()
