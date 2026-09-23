"""User-editable bindings, stored in the XDG config directory.

Everything the UI can remap lives in one JSON file so the engine and the app
agree on a single source of truth:

    ~/.config/gamepad-midi/mapping.json
"""

import copy
import json
import os

from evdev import ecodes as E

CONFIG_DIR = os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
    "gamepad-midi")
CONFIG_PATH = os.path.join(CONFIG_DIR, "mapping.json")
VERSION = 1

# Buttons we expose for remapping, in the order the UI shows them.
BUTTONS = [
    ("BTN_SOUTH", "Cross / A"), ("BTN_EAST", "Circle / B"),
    ("BTN_WEST", "Square / X"), ("BTN_NORTH", "Triangle / Y"),
    ("BTN_TL", "L1 / LB"), ("BTN_TR", "R1 / RB"),
    ("BTN_TL2", "L2 click"), ("BTN_TR2", "R2 click"),
    ("BTN_THUMBL", "L3"), ("BTN_THUMBR", "R3"),
    ("BTN_SELECT", "Share / Back"), ("BTN_START", "Options / Start"),
    ("BTN_MODE", "PS / Guide"),
    ("DPAD_UP", "D-pad up"), ("DPAD_DOWN", "D-pad down"),
    ("DPAD_LEFT", "D-pad left"), ("DPAD_RIGHT", "D-pad right"),
]

# Analog controls we expose, and what each is called in the UI.
AXES = [
    ("left_x", "Left stick — left/right"),
    ("left_y", "Left stick — up/down"),
    ("right_x", "Right stick — left/right"),
    ("right_y", "Right stick — up/down"),
    ("l2", "L2 trigger"),
    ("r2", "R2 trigger"),
    ("touch_x", "Touchpad — left/right"),
    ("touch_y", "Touchpad — up/down"),
]

# What an analog control can be made to do. Several may apply to one axis.
AXIS_ACTIONS = [
    ("pitch_bend", "MIDI pitch bend", "Bends the synth up and down"),
    ("mic_pitch", "Microphone pitch", "Pitch-shifts your voice, up to an octave"),
    ("mic_level", "Microphone level", "Fades the mic in and out"),
    ("mod_wheel", "Mod wheel (CC 1)", "Vibrato on most synths"),
    ("volume", "Volume (CC 7)", "Channel volume"),
    ("pan", "Pan (CC 10)", "Left/right placement"),
    ("expression", "Expression (CC 11)", "Second volume control"),
    ("cutoff", "Filter cutoff (CC 74)", "Brightness"),
    ("resonance", "Filter resonance (CC 71)", "Emphasis at the cutoff"),
    ("reverb", "Reverb send (CC 91)", "Space around the sound"),
    ("chorus", "Chorus send (CC 93)", "Thickens and detunes"),
]

# Action name -> MIDI CC number, for the plain controller-change actions.
ACTION_CC = {
    "mod_wheel": 1, "volume": 7, "pan": 10, "expression": 11,
    "cutoff": 74, "resonance": 71, "reverb": 91, "chorus": 93,
}

DEFAULTS = {
    "version": VERSION,
    # GM percussion key map.
    "drums": {
        "BTN_SOUTH": 36, "BTN_EAST": 38, "BTN_WEST": 42, "BTN_NORTH": 46,
        "BTN_TL": 49, "BTN_TR": 51, "BTN_TL2": 39, "BTN_TR2": 37,
        "BTN_THUMBL": 56, "BTN_THUMBR": 54, "BTN_SELECT": 75,
        "BTN_START": 55, "BTN_MODE": 57,
        "DPAD_UP": 50, "DPAD_DOWN": 41, "DPAD_LEFT": 45, "DPAD_RIGHT": 48,
    },
    # C major around middle C.
    "melodic": {
        "BTN_SOUTH": 60, "BTN_EAST": 62, "BTN_WEST": 64, "BTN_NORTH": 65,
        "BTN_TL": 67, "BTN_TR": 69, "BTN_TL2": 74, "BTN_TR2": 76,
        "BTN_THUMBL": 71, "BTN_THUMBR": 72, "BTN_SELECT": 48,
        "BTN_START": 50, "BTN_MODE": 52,
        "DPAD_UP": 53, "DPAD_DOWN": 55, "DPAD_LEFT": 57, "DPAD_RIGHT": 59,
    },
    "axes": {
        "left_y": ["pitch_bend", "mic_pitch"],
        "left_x": ["mic_level"],
        "right_y": ["pitch_bend"],
        "right_x": [],
        "l2": [],
        "r2": [],
        "touch_x": [],
        "touch_y": [],
    },
    "output": {
        "combine": False,       # collect synth + mic into one virtual sink
        "monitor_sink": None,   # where the combined bus is played back
    },
    "mic": {
        "monitor": True,        # route the mic to the speakers (off = no feedback)
        "pitch_follow": True,   # let a stick pitch-shift the mic at all
        "shift_range": 12,      # semitones at full stick deflection
    },
    "invert": {               # per-axis direction flip, on top of the defaults
        "left_y": False, "right_y": False, "left_x": False,
        "right_x": False, "l2": False, "r2": False,
        "touch_x": False, "touch_y": False,
    },
}

# Names the UI uses -> evdev button codes. D-pad entries are handled as hats
# when the controller reports them that way, and as buttons when it does not.
BUTTON_CODES = {
    "BTN_SOUTH": E.BTN_SOUTH, "BTN_EAST": E.BTN_EAST, "BTN_WEST": E.BTN_WEST,
    "BTN_NORTH": E.BTN_NORTH, "BTN_TL": E.BTN_TL, "BTN_TR": E.BTN_TR,
    "BTN_TL2": E.BTN_TL2, "BTN_TR2": E.BTN_TR2, "BTN_THUMBL": E.BTN_THUMBL,
    "BTN_THUMBR": E.BTN_THUMBR, "BTN_SELECT": E.BTN_SELECT,
    "BTN_START": E.BTN_START, "BTN_MODE": E.BTN_MODE,
    "DPAD_UP": E.BTN_DPAD_UP, "DPAD_DOWN": E.BTN_DPAD_DOWN,
    "DPAD_LEFT": E.BTN_DPAD_LEFT, "DPAD_RIGHT": E.BTN_DPAD_RIGHT,
}

HAT_KEYS = {
    (E.ABS_HAT0Y, -1): "DPAD_UP", (E.ABS_HAT0Y, 1): "DPAD_DOWN",
    (E.ABS_HAT0X, -1): "DPAD_LEFT", (E.ABS_HAT0X, 1): "DPAD_RIGHT",
}


def _merge(base, loaded):
    """Fill anything missing from a loaded config with the default."""
    out = copy.deepcopy(base)
    if not isinstance(loaded, dict):
        return out
    for key, value in loaded.items():
        if key in out and isinstance(out[key], dict) and isinstance(value, dict):
            out[key].update(value)
        elif key in out:
            out[key] = value
    return out


def load():
    try:
        with open(CONFIG_PATH) as fh:
            return _merge(DEFAULTS, json.load(fh))
    except (OSError, ValueError):
        return copy.deepcopy(DEFAULTS)


def save(cfg):
    try:
        os.makedirs(CONFIG_DIR, exist_ok=True)
        tmp = CONFIG_PATH + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(cfg, fh, indent=2, sort_keys=True)
        os.replace(tmp, CONFIG_PATH)
        return True
    except OSError:
        return False


def reset():
    cfg = copy.deepcopy(DEFAULTS)
    save(cfg)
    return cfg


def schema():
    """Everything the UI needs to render the binding editor."""
    return {
        "buttons": [{"key": k, "label": lbl} for k, lbl in BUTTONS],
        "axes": [{"key": k, "label": lbl} for k, lbl in AXES],
        "actions": [{"key": k, "label": lbl, "detail": d} for k, lbl, d in AXIS_ACTIONS],
        "path": CONFIG_PATH,
    }
