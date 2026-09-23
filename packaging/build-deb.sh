#!/usr/bin/env bash
# Build gamepad-midi_<version>_amd64.deb from this checkout.
#
#   ./packaging/build-deb.sh            build UI + backend, produce the .deb
#   ./packaging/build-deb.sh --no-ui    backend and CLI only (no Flutter needed)
#
# The result lands in dist/.
set -euo pipefail

VERSION="0.1.0"
ARCH="$(dpkg --print-architecture)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="$ROOT/build/deb"
DIST="$ROOT/dist"
PKG="gamepad-midi_${VERSION}_${ARCH}"

BUILD_UI=1
[[ "${1:-}" == "--no-ui" ]] && BUILD_UI=0

rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" \
         "$STAGE/usr/bin" \
         "$STAGE/usr/lib/gamepad-midi" \
         "$STAGE/usr/share/applications" \
         "$STAGE/usr/share/doc/gamepad-midi" \
         "$DIST"

# ---------------------------------------------------------------- backend
cp -r "$ROOT/backend/gamepad_midi" "$STAGE/usr/lib/gamepad-midi/"
find "$STAGE/usr/lib/gamepad-midi" -name '__pycache__' -type d -exec rm -rf {} +

cat > "$STAGE/usr/bin/gamepad-midi" <<'EOF'
#!/bin/sh
# Entry point for the gamepad-midi engine and its JSON control server.
exec python3 -c 'import sys; sys.path.insert(0, "/usr/lib/gamepad-midi"); from gamepad_midi.__main__ import main; main()' "$@"
EOF
chmod 755 "$STAGE/usr/bin/gamepad-midi"

# -------------------------------------------------------------------- ui
if [[ $BUILD_UI -eq 1 ]]; then
    echo "Building the Flutter UI..."
    # Icon tree-shaking has silently dropped glyphs we reference, leaving
    # tofu boxes in the UI. The full icon font costs ~1.5MB; keep it.
    ( cd "$ROOT/ui" && flutter build linux --release --no-tree-shake-icons )
    BUNDLE="$ROOT/ui/build/linux/$(uname -m | sed 's/x86_64/x64/;s/aarch64/arm64/')/release/bundle"
    [[ -d "$BUNDLE" ]] || { echo "UI bundle not found at $BUNDLE" >&2; exit 1; }
    cp -r "$BUNDLE" "$STAGE/usr/lib/gamepad-midi/ui"

    cat > "$STAGE/usr/bin/gamepad-midi-ui" <<'EOF'
#!/bin/sh
exec /usr/lib/gamepad-midi/ui/gamepad_midi_ui "$@"
EOF
    chmod 755 "$STAGE/usr/bin/gamepad-midi-ui"

    # Icon comes from the stock Adwaita theme - no bundled artwork.
    cat > "$STAGE/usr/share/applications/gamepad-midi.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Gamepad MIDI
GenericName=MIDI Controller
Comment=Play MIDI with a game controller
Exec=gamepad-midi-ui
Icon=audio-card
Terminal=false
Categories=AudioVideo;Audio;Midi;
Keywords=midi;gamepad;controller;synth;music;
EOF
fi

# ------------------------------------------------------------- metadata
INSTALLED_KB=$(du -sk "$STAGE" | cut -f1)

cat > "$STAGE/DEBIAN/control" <<EOF
Package: gamepad-midi
Version: $VERSION
Section: sound
Priority: optional
Architecture: $ARCH
Depends: python3 (>= 3.9), python3-evdev, python3-mido, python3-rtmidi, alsa-utils
Recommends: fluidsynth, fluid-soundfont-gm, pipewire, pipewire-audio-client-libraries, tap-plugins, pulseaudio-utils, wireplumber
Installed-Size: $INSTALLED_KB
Maintainer: Ethan <ethancalwood13@gmail.com>
Description: Play MIDI with a game controller
 Turns a DualShock 4, Xbox or any other evdev gamepad into a MIDI instrument.
 Buttons play the General MIDI drum kit or a melodic instrument of your choice,
 and both sticks bend pitch.
 .
 A microphone can optionally be mixed in and pitch-shifted live with the left
 stick, using the TAP Pitch Shifter in a PipeWire filter chain. At rest the mic
 passes through dry, so the shifter adds no latency until it is used.
 .
 Ships a command line tool and a Material Design desktop app.
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database -q /usr/share/applications || true
    fi
    # Reading a controller needs membership of the "input" group.
    if ! id -nG "${SUDO_USER:-$USER}" 2>/dev/null | grep -qw input; then
        echo ""
        echo "gamepad-midi: to use a controller without root, run:"
        echo "    sudo usermod -aG input ${SUDO_USER:-$USER}"
        echo "then log out and back in."
        echo ""
    fi
fi
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst"

cat > "$STAGE/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "remove" ] && command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications || true
fi
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postrm"

cp "$ROOT/README.md" "$STAGE/usr/share/doc/gamepad-midi/" 2>/dev/null || true
gzip -9n "$STAGE/usr/share/doc/gamepad-midi/README.md" 2>/dev/null || true

find "$STAGE" -type d -exec chmod 755 {} +
dpkg-deb --root-owner-group --build "$STAGE" "$DIST/$PKG.deb"
echo
echo "Built $DIST/$PKG.deb"
dpkg-deb --info "$DIST/$PKG.deb" | sed -n '1,12p'
