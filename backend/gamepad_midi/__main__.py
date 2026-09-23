"""CLI and JSON-line control server for gamepad-midi.

Two ways to run it:

  gamepad-midi                 interactive: start playing straight away
  gamepad-midi --serve         read JSON commands on stdin, emit JSON events
                               on stdout (this is what the Flutter UI drives)

Protocol (one JSON object per line, both directions):

  -> {"cmd": "start", "device": "/dev/input/event31"}
  -> {"cmd": "set_mode", "mode": "melodic"}
  -> {"cmd": "set_program", "program": 40}
  -> {"cmd": "set_mic", "enabled": true, "source": "alsa_input...."}
  -> {"cmd": "connect", "destination": "FLUID Synth"}
  -> {"cmd": "list"} / {"cmd": "state"} / {"cmd": "stop"} / {"cmd": "quit"}

  <- {"event": "state", ...} | {"event": "note", ...} | {"event": "bend", ...}
  <- {"event": "error", "message": "..."}
"""

import argparse
import json
import signal
import sys
import threading

from . import audio, devices, gm
from .engine import Engine

_write_lock = threading.Lock()


def emit(kind, data=None):
    payload = {"event": kind}
    payload.update(data or {})
    with _write_lock:
        sys.stdout.write(json.dumps(payload) + "\n")
        sys.stdout.flush()


def inventory():
    return {
        "gamepads": devices.list_gamepads(),
        "sources": audio.list_sources(),
        "sinks": audio.list_sinks(),
        "destinations": Engine.list_destinations(),
        "programs": gm.GM_PROGRAMS,
        "families": gm.GM_FAMILIES,
        "mic_available": audio.available(),
    }


def serve(engine):
    emit("inventory", inventory())
    emit("state", engine.state())

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            emit("error", {"message": "malformed command"})
            continue

        cmd = msg.get("cmd")
        try:
            if cmd == "start":
                ok, detail = engine.start(msg.get("device"))
                if not ok:
                    emit("error", {"message": detail})
            elif cmd == "stop":
                engine.stop()
            elif cmd == "set_mode":
                engine.set_mode(msg.get("mode", "drums"))
            elif cmd == "set_program":
                engine.send_program(msg.get("program", 0))
            elif cmd == "set_mic":
                engine.set_mic(msg.get("enabled"), msg.get("source"), msg.get("sink"))
            elif cmd == "connect":
                engine.connect_to(msg.get("destination"))
            elif cmd == "list":
                emit("inventory", inventory())
            elif cmd == "state":
                emit("state", engine.state())
            elif cmd == "quit":
                break
            else:
                emit("error", {"message": f"unknown command: {cmd}"})
        except Exception as exc:                     # keep the server alive
            emit("error", {"message": f"{cmd} failed: {exc}"})

    engine.stop()


def run_cli(engine, args):
    ok, detail = engine.start(args.device)
    if not ok:
        sys.exit(detail)

    state = engine.state()
    print(f"Controller : {state['device_name']}  ({state['device']})")
    for extra in state["extra_devices"]:
        print(f"             + {extra}")
    print(f"MIDI out   : '{engine.__class__.__module__.split('.')[0]}' port "
          f"\"Gamepad MIDI\", channel {state['channel']} ({state['mode']})")
    if state["mode"] == "melodic":
        print(f"Program    : {engine.program} - {gm.program_name(engine.program)}")
    if state["mic_enabled"]:
        print(f"Microphone : {state['mic_source'] or 'default'} "
              f"(left stick Y shifts pitch, left stick X fades level)")
    print("Ctrl-C to quit.")

    stop = threading.Event()
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    while not stop.is_set() and engine.running:
        stop.wait(0.3)
    engine.stop()
    print("\nStopped.")


def main(argv=None):
    ap = argparse.ArgumentParser(prog="gamepad-midi",
                                 description="Play MIDI with a game controller.")
    ap.add_argument("--serve", action="store_true",
                    help="JSON control server on stdin/stdout (used by the UI)")
    ap.add_argument("--device", help="gamepad evdev path, e.g. /dev/input/event31")
    ap.add_argument("--list", action="store_true", help="list controllers and exit")
    ap.add_argument("--melodic", action="store_true",
                    help="melodic notes on channel 1 instead of drums on channel 10")
    ap.add_argument("--program", type=int, default=0, metavar="N",
                    help="GM program 0-127 for melodic mode")
    ap.add_argument("--mic", action="store_true", help="enable the microphone path")
    ap.add_argument("--mic-source", help="PipeWire source name for the microphone")
    ap.add_argument("--connect", metavar="DEST",
                    help="ALSA client to auto-connect to, e.g. 'FLUID Synth'")
    ap.add_argument("--no-grab", action="store_true",
                    help="do not take exclusive control of the controller")
    args = ap.parse_args(argv)

    if args.list:
        for pad in devices.list_gamepads():
            print(f"{pad['path']}\t{pad['name']}")
            for sib in pad["siblings"]:
                print(f"  + {sib}")
        print("\nMIDI destinations:")
        for dest in Engine.list_destinations():
            print(f"  {dest['client']} : {dest['port']}")
        print("\nMicrophone sources:")
        for src in audio.list_sources():
            print(f"  {'*' if src['default'] else ' '} {src['description']}")
            print(f"    {src['name']}")
        return

    engine = Engine(on_event=lambda kind, data: emit(kind, data) if args.serve else None)
    engine.mode = "melodic" if args.melodic else "drums"
    engine.channel = 0 if args.melodic else 9
    engine.program = max(0, min(127, args.program))
    engine.destination = args.connect
    engine.mic_enabled = args.mic
    engine.mic_source = args.mic_source
    engine.grab = not args.no_grab

    if args.serve:
        serve(engine)
    else:
        run_cli(engine, args)


if __name__ == "__main__":
    main()
