# Gamepad MIDI

Play MIDI with a game controller on Linux. Buttons trigger the General MIDI
drum kit or a melodic instrument; both sticks bend pitch; your microphone can
optionally be mixed in and pitch-shifted live with the left stick.

Works with any evdev gamepad — DualShock 4, Xbox, 8BitDo and so on. On a DS4
the touchpad and motion sensors are opened alongside the pad and held
exclusively, so the touchpad stops driving the desktop mouse while you play.

## Install

```
sudo dpkg -i dist/gamepad-midi_0.1.0_amd64.deb
sudo apt -f install          # pull in any missing dependencies
```

Reading a controller without root needs the `input` group:

```
sudo usermod -aG input "$USER"
```

Log out and back in for that to take effect.

## Use

Launch **Gamepad MIDI** from your application menu, or:

```
gamepad-midi-ui          # desktop app
gamepad-midi             # command line, drums, auto-detect
gamepad-midi --melodic --program 40 --connect 'FLUID Synth'
gamepad-midi --list      # controllers, MIDI destinations, microphones
```

You need something to make the sound. FluidSynth is the simplest:

```
fluidsynth -is -a pulseaudio -m alsa_seq -o synth.chorus.active=0 \
    /usr/share/sounds/sf2/FluidR3_GM.sf2
```

Then pick it under **MIDI output** in the app. Any DAW that accepts ALSA
sequencer input (Ardour, LMMS, Reaper, Qtractor) works the same way.

## Controls

| Control | Effect |
| --- | --- |
| Left stick, up/down | Pitch bend, and shifts the microphone when it is on |
| Left stick, left/right | Fades the microphone level |
| Right stick, up/down | Pitch bend only |
| Cross / Circle / Square / Triangle | Kick, snare, closed hat, open hat |
| L1 / R1 | Crash, ride |
| D-pad | Toms |
| L2 / R2 click | Hand clap, side stick |
| L3 / R3 | Cowbell, tambourine |

In melodic mode the same buttons play a C major scale around middle C and the
instrument is whichever General MIDI program you pick.

## Microphone

Optional. When enabled, the mic is routed through a PipeWire filter chain built
around the TAP Pitch Shifter:

```
mic -> [ tap_pitch ] -> output
```

The plugin's dry output is the undelayed input, so while the left stick is
centred the chain runs 100% dry and adds no latency. Moving the stick
crossfades to the shifted signal, which carries the shifter's own delay
(roughly 20–45 ms). Full deflection is one octave.

Needs `pipewire` and `tap-plugins`. Without them the microphone section is
disabled and everything else still works.

## Layout

```
backend/gamepad_midi/     engine, evdev handling, mic chain, JSON control server
ui/                       Flutter Material 3 desktop app
packaging/build-deb.sh    builds the .deb
```

The UI launches `gamepad-midi --serve` and talks to it over a JSON-line
protocol on stdin/stdout, so the engine runs headless just as well.

## Building

```
sudo apt install fluidsynth python3-mido python3-rtmidi python3-evdev \
    tap-plugins clang cmake ninja-build libgtk-3-dev pkg-config g++

./packaging/build-deb.sh            # UI + backend
./packaging/build-deb.sh --no-ui    # backend only, no Flutter needed
```

Building the UI needs the Flutter SDK on `PATH`.

## Mapping changes

The note tables live in `backend/gamepad_midi/mapping.py` — plain dictionaries
of evdev button code to MIDI note. Run `gamepad-midi --list` to find device
paths; run the engine with `--no-grab` if you want the controller to keep
working as a normal input device while it plays.
