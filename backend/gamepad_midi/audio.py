"""Optional microphone path: PipeWire filter-chain around the TAP Pitch Shifter.

The chain is mono in / mono out:

    <mic source> -> [ tap_pitch ] -> <output sink>

The plugin's dry signal is the undelayed input, so at 0 semitones we run
100% dry and the mic is a straight passthrough with no plugin latency. As the
stick leaves centre we crossfade to the wet (shifted) signal.
"""

import json
import os
import shutil
import subprocess
import tempfile

PLUGIN_PATH = "/usr/lib/ladspa/tap_pitch.so"
PLUGIN_LABEL = "tap_pitch"
NODE_NAME = "gamepad_midi_mic"
GRAPH_NODE = "pitch"

# Below this |shift| in semitones the chain stays fully dry (zero added latency).
DRY_EPSILON = 0.15
WET_OFF_DB = -90.0
DRY_OFF_DB = -90.0

CONF_TEMPLATE = """\
context.properties = {{
    log.level = 0
}}

context.spa-libs = {{
    audio.convert.* = audioconvert/libspa-audioconvert
    support.*       = support/libspa-support
}}

context.modules = [
    {{ name = libpipewire-module-rt
        args = {{
            nice.level = -11
        }}
        flags = [ ifexists nofail ]
    }}
    {{ name = libpipewire-module-protocol-native }}
    {{ name = libpipewire-module-client-node }}
    {{ name = libpipewire-module-adapter }}
    {{ name = libpipewire-module-filter-chain
        args = {{
            node.description = "Gamepad MIDI Mic"
            media.name       = "Gamepad MIDI Mic"
            filter.graph = {{
                nodes = [
                    {{
                        type   = ladspa
                        plugin = "{plugin}"
                        label  = "{label}"
                        name   = "{graph_node}"
                        control = {{
                            "Semitone Shift" = 0.0
                            "Rate Shift [%]" = 0.0
                            "Dry Level [dB]" = 0.0
                            "Wet Level [dB]" = {wet_off}
                        }}
                    }}
                ]
            }}
            capture.props = {{
                node.name       = "{node}_capture"
                node.passive    = false
                node.autoconnect = true
                {target_source}
            }}
            playback.props = {{
                node.name       = "{node}_playback"
                node.autoconnect = true
                {target_sink}
            }}
        }}
    }}
]
"""


def available():
    return os.path.exists(PLUGIN_PATH) and shutil.which("pipewire") is not None


def list_sources():
    """Audio capture devices as [{name, description, default}]."""
    if not shutil.which("pactl"):
        return []
    try:
        raw = subprocess.run(["pactl", "-f", "json", "list", "sources"],
                             capture_output=True, text=True, timeout=5).stdout
        sources = json.loads(raw)
        default = subprocess.run(["pactl", "get-default-source"],
                                 capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, ValueError, subprocess.SubprocessError):
        return []
    out = []
    for s in sources:
        name = s.get("name", "")
        if name.endswith(".monitor"):      # loopback of an output, not a mic
            continue
        out.append({"name": name,
                    "description": s.get("description") or name,
                    "default": name == default})
    return out


def list_sinks():
    if not shutil.which("pactl"):
        return []
    try:
        raw = subprocess.run(["pactl", "-f", "json", "list", "sinks"],
                             capture_output=True, text=True, timeout=5).stdout
        sinks = json.loads(raw)
        default = subprocess.run(["pactl", "get-default-sink"],
                                 capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, ValueError, subprocess.SubprocessError):
        return []
    return [{"name": s.get("name", ""),
             "description": s.get("description") or s.get("name", ""),
             "default": s.get("name") == default} for s in sinks]


class MicChain:
    """Runs (and live-controls) the mic filter chain as a child pipewire process."""

    def __init__(self):
        self.proc = None
        self.conf_path = None
        self._node_id = None
        self._last_shift = None
        self._last_level = None

    @property
    def running(self):
        return self.proc is not None and self.proc.poll() is None

    def start(self, source=None, sink=None):
        if self.running:
            return True
        if not available():
            return False

        conf = CONF_TEMPLATE.format(
            plugin=PLUGIN_PATH, label=PLUGIN_LABEL, graph_node=GRAPH_NODE,
            node=NODE_NAME, wet_off=WET_OFF_DB,
            target_source=f'target.object = "{source}"' if source else "",
            target_sink=f'target.object = "{sink}"' if sink else "",
        )
        fd, self.conf_path = tempfile.mkstemp(prefix="gamepad-midi-mic-", suffix=".conf")
        with os.fdopen(fd, "w") as fh:
            fh.write(conf)

        self.proc = subprocess.Popen(
            ["pipewire", "-c", self.conf_path],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self._node_id = None
        self._last_shift = self._last_level = None
        return True

    def stop(self):
        if self.proc is not None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
            self.proc = None
        if self.conf_path and os.path.exists(self.conf_path):
            os.unlink(self.conf_path)
        self.conf_path = None
        self._node_id = None

    # ------------------------------------------------------------- live control
    def _find_node(self):
        if self._node_id is not None:
            return self._node_id
        try:
            dump = json.loads(subprocess.run(["pw-dump"], capture_output=True,
                                             text=True, timeout=5).stdout)
        except (OSError, ValueError, subprocess.SubprocessError):
            return None
        for obj in dump:
            props = obj.get("info", {}).get("props", {})
            if props.get("node.name") == f"{NODE_NAME}_capture":
                self._node_id = obj.get("id")
                return self._node_id
        return None

    def set_shift(self, semitones):
        """semitones: float, typically -12..+12. 0 means fully dry."""
        semitones = round(max(-24.0, min(24.0, float(semitones))), 2)
        if semitones == self._last_shift or not self.running:
            return
        self._last_shift = semitones

        node = self._find_node()
        if node is None:
            return
        if abs(semitones) < DRY_EPSILON:
            dry, wet = 0.0, WET_OFF_DB      # passthrough, no plugin latency
        else:
            dry, wet = DRY_OFF_DB, 0.0      # shifted signal only
        params = (f'{{ params = [ "{GRAPH_NODE}:Semitone Shift" {semitones} '
                  f'"{GRAPH_NODE}:Dry Level [dB]" {dry} '
                  f'"{GRAPH_NODE}:Wet Level [dB]" {wet} ] }}')
        subprocess.run(["pw-cli", "set-param", str(node), "Props", params],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def set_level(self, level):
        """level: 0.0 - 1.0 mic volume."""
        level = round(max(0.0, min(1.0, float(level))), 3)
        if level == self._last_level or not self.running:
            return
        self._last_level = level
        node = self._find_node()
        if node is None:
            return
        subprocess.run(["wpctl", "set-volume", str(node), f"{level}"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def error_output(self):
        if self.proc and self.proc.poll() is not None and self.proc.stderr:
            try:
                return self.proc.stderr.read().decode(errors="replace")[-500:]
            except (OSError, ValueError):
                return ""
        return ""
