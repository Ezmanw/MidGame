"""Turns the stored configuration into lookup tables the event loop can use."""

from evdev import ecodes as E

from . import config

VELOCITY = 110
DEADZONE = 0.08


def note_tables(cfg, mode):
    """(button code -> note, (hat axis, direction) -> note) for one mode."""
    bindings = cfg.get(mode, {})
    buttons, hats = {}, {}
    for key, note in bindings.items():
        if note is None:
            continue
        code = config.BUTTON_CODES.get(key)
        if code is not None:
            buttons[code] = int(note)
    for (axis, direction), key in config.HAT_KEYS.items():
        if bindings.get(key) is not None:
            hats[(axis, direction)] = int(bindings[key])
    return buttons, hats


class Axis:
    """Scales one evdev absolute axis to -1..1 (centred) or 0..1 (trigger)."""

    def __init__(self, absinfo, centred, invert=False):
        self.lo, self.hi = absinfo.min, absinfo.max
        self.centred = centred
        self.invert = invert
        self.value = 0.0

    def update(self, raw):
        span = (self.hi - self.lo) or 1
        f = (raw - self.lo) / span
        if self.invert:
            f = 1.0 - f
        if self.centred:
            v = f * 2.0 - 1.0
            if abs(v) < DEADZONE:
                v = 0.0
            else:   # rescale past the deadzone so the travel stays smooth
                v = (abs(v) - DEADZONE) / (1.0 - DEADZONE) * (1 if v > 0 else -1)
                v = max(-1.0, min(1.0, v))
        else:
            v = f
        changed = abs(v - self.value) > 1e-4
        self.value = v
        return changed


def _is_trigger(code, info):
    # A trigger rests at its minimum; a stick rests in the middle.
    return code in (E.ABS_BRAKE, E.ABS_GAS) or (
        code in (E.ABS_Z, E.ABS_RZ) and info.min == 0 and info.max <= 1023)


def build_axes(devices, cfg):
    """Return ({(path, code): Axis}, {role: (path, code)}).

    DS4 and Xbox drivers disagree about which evdev code carries the right
    stick and the triggers, so roles are decided from the reported ranges
    rather than from the code names.
    """
    axes = {}
    roles = {}
    main = devices[0].path if devices else None
    right_y, right_x, triggers = [], [], []
    inverts = cfg.get("invert", {})

    for dev in devices:
        for code, info in dev.capabilities().get(E.EV_ABS, []):
            if code in (E.ABS_HAT0X, E.ABS_HAT0Y):
                continue
            touch = code in (E.ABS_MT_POSITION_X, E.ABS_MT_POSITION_Y)
            trigger = _is_trigger(code, info)
            # Up and right should read positive on every pad.
            invert = code in (E.ABS_Y, E.ABS_RY, E.ABS_RZ, E.ABS_MT_POSITION_Y)
            axes[(dev.path, code)] = Axis(info, centred=not (trigger or touch),
                                          invert=invert)
            if touch:
                role = "touch_x" if code == E.ABS_MT_POSITION_X else "touch_y"
                roles[role] = (dev.path, code)
            elif dev.path == main:
                if code == E.ABS_X:
                    roles["left_x"] = (dev.path, code)
                elif code == E.ABS_Y:
                    roles["left_y"] = (dev.path, code)
                elif trigger:
                    triggers.append((code, dev.path))
                elif code in (E.ABS_RY, E.ABS_RZ):
                    right_y.append((code, dev.path))
                elif code in (E.ABS_RX, E.ABS_Z):
                    right_x.append((code, dev.path))

    if right_y:
        roles["right_y"] = (right_y[0][1], right_y[0][0])
    if right_x:
        roles["right_x"] = (right_x[0][1], right_x[0][0])
    triggers.sort()
    if len(triggers) > 0:
        roles["l2"] = (triggers[0][1], triggers[0][0])
    if len(triggers) > 1:
        roles["r2"] = (triggers[1][1], triggers[1][0])

    # Apply any user-requested direction flips on top of the driver defaults.
    for role, (path, code) in roles.items():
        if inverts.get(role):
            axes[(path, code)].invert = not axes[(path, code)].invert

    return axes, roles
