#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ACTION="${1:-install}"
CAMERA_USER="${SUDO_USER:-$(id -un)}"
CAMERA_UID="$(id -u "$CAMERA_USER")"
CAMERA_GROUP="$(id -gn "$CAMERA_USER")"
CAMERA_HOME="$(getent passwd "$CAMERA_USER" | cut -d: -f6)"
RUNTIME="/run/user/$CAMERA_UID"
MAP="$ROOT/data/lens-shading-measured-raw.bin"
DEST=/usr/local/share/ov5678/lens-shading.bin
PIPEWIRE_DROPIN="$CAMERA_HOME/.config/systemd/user/pipewire.service.d/60-camera-shading.conf"
WIREPLUMBER_DROPIN="$CAMERA_HOME/.config/systemd/user/wireplumber.service.d/60-camera-shading.conf"

validate_map() {
    python3 - "$1" <<'PY'
import os
import struct
import sys
path = sys.argv[1]
with open(path, "rb") as stream:
    header = stream.read(8)
if len(header) != 8:
    sys.exit("ERROR: shading map header is incomplete")
width, height, one, channels = struct.unpack("<4H", header)
expected = 8 + width * height * channels * 2
if (width, height, one, channels) != (63, 47, 2048, 4) or os.path.getsize(path) != expected:
    sys.exit(f"ERROR: invalid shading map format ({width}x{height}, scale={one}, channels={channels})")
PY
}

restart_desktop_camera() {
    runuser -u "$CAMERA_USER" -- env XDG_RUNTIME_DIR="$RUNTIME" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME/bus" \
        systemctl --user daemon-reload
    runuser -u "$CAMERA_USER" -- env XDG_RUNTIME_DIR="$RUNTIME" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME/bus" \
        systemctl --user restart pipewire wireplumber
}

case "$ACTION" in
    check)
        [[ -f "$MAP" ]] || { echo "No measured map at $MAP" >&2; exit 1; }
        validate_map "$MAP"
        bash -n "$0"
        echo "PASS: measured front-camera shading map is valid"
        exit 0
        ;;
    install|revert) ;;
    *) echo "Usage: $0 [check|install|revert]" >&2; exit 1 ;;
esac

[[ "$(id -u)" == 0 ]] || { echo "Run with sudo: bash $0 $ACTION" >&2; exit 1; }
[[ -n "${SUDO_USER:-}" && "$CAMERA_UID" != 0 ]] || {
    echo "Run sudo from your desktop user's terminal." >&2
    exit 1
}
[[ -S "$RUNTIME/pipewire-0" ]] || { echo "The desktop PipeWire service is not available." >&2; exit 1; }

if [[ "$ACTION" == revert ]]; then
    rm -f "$PIPEWIRE_DROPIN" "$WIREPLUMBER_DROPIN"
    restart_desktop_camera
    echo "PipeWire no longer loads lens shading. The measured map remains at $DEST."
    exit 0
fi

[[ -f "$MAP" ]] || { echo "No measured map at $MAP; run tools/measure-lens-shading.sh --raw first." >&2; exit 1; }
validate_map "$MAP"
for dropin in "$PIPEWIRE_DROPIN" "$WIREPLUMBER_DROPIN"; do
    if [[ -e "$dropin" ]] && ! grep -Fxq 'Environment="RGBIR_SHADING=/usr/local/share/ov5678/lens-shading.bin"' "$dropin"; then
        echo "Refusing to overwrite an existing shading drop-in: $dropin" >&2
        exit 1
    fi
done

install -D -m644 "$MAP" "$DEST"
for dropin in "$PIPEWIRE_DROPIN" "$WIREPLUMBER_DROPIN"; do
    install -d -o "$CAMERA_USER" -g "$CAMERA_GROUP" -m755 "$(dirname "$dropin")"
    printf '[Service]\nEnvironment="RGBIR_SHADING=%s"\n' "$DEST" > "$dropin"
    chown "$CAMERA_USER:$CAMERA_GROUP" "$dropin"
    chmod 644 "$dropin"
done
restart_desktop_camera
printf 'Installed measured map: %s\n' "$DEST"

echo "PipeWire and WirePlumber restarted; close and reopen camera apps to use the map."
