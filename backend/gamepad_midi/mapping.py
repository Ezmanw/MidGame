"""Button -> note tables and analog axis scaling."""

from evdev import ecodes as E

VELOCITY = 110
DEADZONE = 0.08

# --- drum mode: GM percussion key map on channel 10 -------------------------
DRUM_BUTTONS = {
    E.BTN_SOUTH: 36,      # Cross    -> Bass Drum 1
    E.BTN_EAST: 38,       # Circle   -> Acoustic Snare
    E.BTN_WEST: 42,       # Square   -> Closed Hi Hat
    E.BTN_NORTH: 46,      # Triangle -> Open Hi-Hat
    E.BTN_TL: 49,         # L1       -> Crash Cymbal 1
    E.BTN_TR: 51,         # R1       -> Ride Cymbal 1
    E.BTN_TL2: 39,        # L2 click -> Hand Clap
    E.BTN_TR2: 37,        # R2 click -> Side Stick
    E.BTN_THUMBL: 56,     # L3       -> Cowbell
    E.BTN_THUMBR: 54,     # R3       -> Tambourine
    E.BTN_SELECT: 75,     # Share    -> Claves
    E.BTN_START: 55,      # Options  -> Splash Cymbal
    E.BTN_MODE: 57,       # PS       -> Crash Cymbal 2
    E.BTN_DPAD_UP: 50, E.BTN_DPAD_DOWN: 41,
    E.BTN_DPAD_LEFT: 45, E.BTN_DPAD_RIGHT: 48,
}
DRUM_HAT = {
    (E.ABS_HAT0Y, -1): 50,   # up    -> High Tom
    (E.ABS_HAT0Y, 1): 41,    # down  -> Low Floor Tom
    (E.ABS_HAT0X, -1): 45,   # left  -> Low Tom
    (E.ABS_HAT0X, 1): 48,    # right -> Hi-Mid Tom
}

# --- melodic mode: C major scale around middle C ---------------------------
MELODIC_BUTTONS = {
    E.BTN_SOUTH: 60, E.BTN_EAST: 62, E.BTN_WEST: 64, E.BTN_NORTH: 65,
    E.BTN_TL: 67, E.BTN_TR: 69, E.BTN_THUMBL: 71, E.BTN_THUMBR: 72,
    E.BTN_SELECT: 48, E.BTN_START: 50, E.BTN_MODE: 52,
    E.BTN_DPAD_UP: 53, E.BTN_DPAD_DOWN: 55,
    E.BTN_DPAD_LEFT: 57, E.BTN_DPAD_RIGHT: 59,
    E.BTN_TL2: 74, E.BTN_TR2: 76,
}
MELODIC_HAT = {
    (E.ABS_HAT0Y, -1): 53, (E.ABS_HAT0Y, 1): 55,
    (E.ABS_HAT0X, -1): 57, (E.ABS_HAT0X, 1): 59,
}

BUTTON_LABELS = {
    E.BTN_SOUTH: "Cross / A", E.BTN_EAST: "Circle / B",
    E.BTN_WEST: "Square / X", E.BTN_NORTH: "Triangle / Y",
    E.BTN_TL: "L1 / LB", E.BTN_TR: "R1 / RB",
    E.BTN_TL2: "L2", E.BTN_TR2: "R2",
    E.BTN_THUMBL: "L3", E.BTN_THUMBR: "R3",
    E.BTN_SELECT: "Share / Back", E.BTN_START: "Options / Start",
    E.BTN_MODE: "PS / Guide",
    E.BTN_DPAD_UP: "D-pad up", E.BTN_DPAD_DOWN: "D-pad down",
    E.BTN_DPAD_LEFT: "D-pad left", E.BTN_DPAD_RIGHT: "D-pad right",
}
HAT_LABELS = {
    (E.ABS_HAT0Y, -1): "D-pad up", (E.ABS_HAT0Y, 1): "D-pad down",
    (E.ABS_HAT0X, -1): "D-pad left", (E.ABS_HAT0X, 1): "D-pad right",
}


def tables(mode):
    if mode == "melodic":
        return MELODIC_BUTTONS, MELODIC_HAT
    return DRUM_BUTTONS, DRUM_HAT


class Axis:
    """Scales one evdev absolute axis to -1..1 (centred) or 0..1 (trigger)."""

    def __init__(self, absinfo, centred, invert=False):
        self.lo, self.hi = absinfo.min, absinfo.max
        self.centred = centred
        self.invert = invert
        self.value = 0.0

    def update(self, raw):
        f = (raw - self.lo) / ((self.hi - self.lo) or 1)
        if self.invert:
            f = 1.0 - f
        if self.centred:
            v = f * 2.0 - 1.0
            if abs(v) < DEADZONE:
                v = 0.0
            else:                       # rescale so travel past the deadzone is smooth
                v = (abs(v) - DEADZONE) / (1.0 - DEADZONE) * (1 if v > 0 else -1)
        else:
            v = f
        changed = abs(v - self.value) > 1e-4
        self.value = v
        return changed


def classify_axes(devices, roles):
    """Build {(device path, axis code): Axis} and work out which codes are what.

    Sticks report a signed/centred range; triggers start at 0. DS4 and Xbox
    drivers disagree about which code carries the right stick, so decide from
    the reported range rather than the code name.
    """
    axes = {}
    candidates = {"right_y": [], "right_x": []}
    for dev in devices:
        for code, info in dev.capabilities().get(E.EV_ABS, []):
            if code in (E.ABS_HAT0X, E.ABS_HAT0Y):
                continue
            is_touch = code in (E.ABS_MT_POSITION_X, E.ABS_MT_POSITION_Y)
            # A trigger rests at its minimum; a stick rests in the middle.
            is_trigger = code in (E.ABS_BRAKE, E.ABS_GAS) or (
                code in (E.ABS_Z, E.ABS_RZ) and info.min == 0 and info.max <= 1023)
            centred = not (is_trigger or is_touch)
            invert = code in (E.ABS_Y, E.ABS_RY, E.ABS_RZ)   # up should read positive
            axes[(dev.path, code)] = Axis(info, centred, invert)

            if centred and dev.path == devices[0].path:
                if code in (E.ABS_RY, E.ABS_RZ):
                    candidates["right_y"].append(code)
                elif code in (E.ABS_RX, E.ABS_Z):
                    candidates["right_x"].append(code)

    roles["left_y"] = E.ABS_Y
    roles["left_x"] = E.ABS_X
    roles["right_y"] = candidates["right_y"][0] if candidates["right_y"] else None
    roles["right_x"] = candidates["right_x"][0] if candidates["right_x"] else None
    return axes
