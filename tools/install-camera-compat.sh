#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAMERA_USER="${SUDO_USER:-$(id -un)}"
CAMERA_UID="$(id -u "$CAMERA_USER")"
CAMERA_HOME="$(getent passwd "$CAMERA_USER" | cut -d: -f6)"
RUNTIME="/run/user/$CAMERA_UID"
LOOPBACK=/dev/video64
CAMERA_NODE=libcamera_input.__SB_.PC00.LNK0

write_units() {
    local directory="$1"
    mkdir -p "$directory"
    cat > "$directory/ov5678-compat-stream.service" <<EOF
[Unit]
Description=Shared PipeWire camera into V4L2 compatibility device
Requires=user@$CAMERA_UID.service
After=user@$CAMERA_UID.service
StartLimitIntervalSec=0

[Service]
User=$CAMERA_USER
Environment=XDG_RUNTIME_DIR=$RUNTIME
ExecStart=/usr/bin/gst-launch-1.0 -q pipewiresrc target-object=$CAMERA_NODE do-timestamp=true ! queue max-size-buffers=2 max-size-bytes=0 max-size-time=0 leaky=downstream ! video/x-raw,width=1280,height=720 ! videoconvert ! videorate ! video/x-raw,format=YUY2,framerate=30/1 ! v4l2sink device=$LOOPBACK sync=false
Restart=on-failure
RestartSec=2
EOF

    cat > "$directory/ov5678-compat-placeholder.service" <<EOF
[Unit]
Description=Paced idle frames for V4L2 camera discovery
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/bin/gst-launch-1.0 -q videotestsrc is-live=true pattern=black ! video/x-raw,format=YUY2,width=1280,height=720,framerate=30/1 ! v4l2sink device=$LOOPBACK sync=false
ExecStartPost=/usr/bin/timeout 5s /bin/sh -c 'until /usr/bin/v4l2-ctl -d $LOOPBACK --info | /usr/bin/grep -q Video.Capture; do /usr/bin/sleep 0.1; done'
ExecStartPost=/usr/bin/udevadm trigger --action=change /sys/class/video4linux/video64
Restart=on-failure
RestartSec=2
EOF

    cat > "$directory/ov5678-compat.service" <<EOF
[Unit]
Description=On-demand shared camera compatibility bridge
After=systemd-modules-load.service

[Service]
Environment=LOOPBACK=$LOOPBACK
Environment=PRODUCER=ov5678-compat-stream.service
Environment=PLACEHOLDER=ov5678-compat-placeholder.service
ExecStart=/usr/local/libexec/ov5678-ondemand.sh
ExecStopPost=/usr/bin/systemctl stop ov5678-compat-stream.service ov5678-compat-placeholder.service
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

case "${1:-install}" in
    check)
        temporary="$(mktemp -d)"
        trap 'rm -rf "$temporary"' EXIT
        write_units "$temporary"
        systemd-analyze verify "$temporary"/*.service
        bash -n "$HERE/install-rgbir.sh" "$HERE/ov5678-ondemand.sh"
        echo "PASS: compatibility units and shell syntax validated"
        exit 0
        ;;
    install) ;;
    *) echo "Usage: $0 [install|check]" >&2; exit 1 ;;
esac

[[ "$(id -u)" == 0 ]] || { echo "Run with sudo: $0" >&2; exit 1; }
[[ "$CAMERA_UID" != 0 ]] || { echo "Run sudo from your desktop user account." >&2; exit 1; }
[[ -S "$RUNTIME/pipewire-0" ]] || { echo "Your desktop PipeWire service must be running." >&2; exit 1; }
[[ -f "$CAMERA_HOME/.config/systemd/user/pipewire.service.d/50-rgbir-camera.conf" ]] || {
    echo "Configure the corrected native PipeWire camera first." >&2
    exit 1
}
modinfo v4l2loopback >/dev/null

bash "$HERE/install-rgbir.sh" build
bash "$HERE/install-rgbir.sh" enable

install -d /etc/modprobe.d /etc/modules-load.d /etc/udev/rules.d /usr/local/libexec
cat > /etc/modprobe.d/ov5678-compat.conf <<'EOF'
options v4l2loopback devices=1 video_nr=64 exclusive_caps=1 card_label="Camera Compatibility"
EOF
printf '%s\n' v4l2loopback > /etc/modules-load.d/ov5678-compat.conf
cat > /etc/udev/rules.d/71-ov5678-compat.rules <<'EOF'
SUBSYSTEM=="video4linux", KERNEL=="video64", ATTR{name}=="Camera Compatibility", TAG+="uaccess"
EOF
udevadm control --reload-rules
modprobe v4l2loopback
udevadm settle
if ! v4l2-ctl -d "$LOOPBACK" --info | grep -q 'Driver name.*v4l2 loopback'; then
    echo "ERROR: $LOOPBACK is not the expected loopback device; no existing device was unloaded." >&2
    exit 1
fi

systemctl disable --now ov5678-ondemand.service ov5678-camera.service
systemctl stop ov5678-placeholder.service
install -m755 "$HERE/ov5678-ondemand.sh" /usr/local/libexec/ov5678-ondemand.sh
write_units /etc/systemd/system
systemctl daemon-reload

runuser -u "$CAMERA_USER" -- env XDG_RUNTIME_DIR="$RUNTIME" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME/bus" \
    systemctl --user restart pipewire wireplumber

systemctl start ov5678-compat-placeholder.service
systemctl enable --now ov5678-compat.service
echo
systemctl status ov5678-compat.service ov5678-compat-placeholder.service --no-pager -l
echo
echo "Native PipeWire apps: Built-in Front Camera"
echo "V4L2 apps: Camera Compatibility ($LOOPBACK)"
echo "The V4L2 feed starts on demand and shares the native PipeWire camera."
