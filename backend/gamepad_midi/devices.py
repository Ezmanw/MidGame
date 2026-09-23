"""evdev gamepad discovery."""

import evdev
from evdev import ecodes as E


def is_gamepad(dev):
    keys = dev.capabilities().get(E.EV_KEY, [])
    return E.BTN_GAMEPAD in keys or E.BTN_SOUTH in keys


def _open_all():
    devs = []
    for path in evdev.list_devices():
        try:
            devs.append(evdev.InputDevice(path))
        except OSError:
            pass
    return devs


def list_gamepads():
    """[{path, name, siblings: [paths]}] - one entry per physical controller."""
    all_devs = _open_all()
    out = []
    for d in all_devs:
        if not is_gamepad(d):
            continue
        sibs = [s.path for s in all_devs
                if s.path != d.path and s.name.startswith(d.name)]
        out.append({"path": d.path, "name": d.name, "siblings": sibs})
    # Prefer real controllers over keyboard/mouse adapters.
    out.sort(key=lambda e: ("Adapter" in e["name"], "Keyboard" in e["name"], e["path"]))
    return out


def open_group(main_path=None):
    """Open the main gamepad plus its sibling nodes (DS4 touchpad, motion)."""
    all_devs = _open_all()
    if main_path:
        main = next((d for d in all_devs if d.path == main_path), None)
        if main is None:
            main = evdev.InputDevice(main_path)
            all_devs.append(main)
    else:
        pads = list_gamepads()
        if not pads:
            return []
        main = next(d for d in all_devs if d.path == pads[0]["path"])

    group = [main] + [d for d in all_devs
                      if d.path != main.path and d.name.startswith(main.name)]
    for d in all_devs:
        if d not in group:
            d.close()
    return group
