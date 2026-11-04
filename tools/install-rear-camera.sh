#!/bin/bash
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
KERNEL="$(uname -r)"
BACKUP="/var/lib/latitude-7320-rear-camera/$KERNEL"
INITRD="/boot/initrd.img-$KERNEL"
IPU6_FIRMWARE=/lib/firmware/intel/ipu/ipu6_fw.bin.zst
ACTION="${1:-install}"
CAMERA_HOME="$(getent passwd "${SUDO_USER:-$(id -un)}" | cut -d: -f6)"
LIBCAMERA_SRC="$CAMERA_HOME/.cache/libcamera-build/libcamera-src"

restore_originals() {
    local original_path
    original_path="$(<"$BACKUP/board.path")"
    cp -a "$BACKUP/board.original" "$original_path"
    original_path="$(<"$BACKUP/sensor.path")"
    cp -a "$BACKUP/sensor.original" "$original_path"
    cp -a "$BACKUP/initrd.original" "$INITRD"
    depmod -a "$KERNEL"
}

install_module() {
    local candidate="$1" destination="$2"
    case "$destination" in
        *.ko.zst) zstd -q -c "$candidate" > "$destination.rear-new" ;;
        *.ko.xz) xz -c "$candidate" > "$destination.rear-new" ;;
        *.ko) cp "$candidate" "$destination.rear-new" ;;
        *) echo "Unsupported module format: $destination" >&2; return 1 ;;
    esac
    chmod 644 "$destination.rear-new"
    mv -f "$destination.rear-new" "$destination"
}

if [[ "$ACTION" == check ]]; then
    bash -n "$0" "$HERE/build-rear-camera.sh" "$HERE/install-rgbir.sh"
    patch --batch --dry-run --fuzz=0 -p1 -d "$ROOT/module" \
        < "$ROOT/kernel-patches/experimental-ov8856-board-data.patch"
    sources=(/usr/src/ipu6-drivers-*/drivers/media/i2c/ov8856.c)
    [[ "${#sources[@]}" == 1 && -f "${sources[0]}" ]]
    patch --batch --dry-run --fuzz=0 -p1 -d "$(dirname "${sources[0]}")" \
        < "$ROOT/kernel-patches/experimental-ov8856-power.patch"
    patch --batch --dry-run --fuzz=0 -p1 -d "$(dirname "${sources[0]}")" \
        < "$ROOT/kernel-patches/experimental-ov8856-selection.patch"
    if ! patch --batch --dry-run --fuzz=0 -p1 -d "$LIBCAMERA_SRC" \
        < "$ROOT/libcamera-patch/experimental-ov8856-support.patch" >/dev/null 2>&1 &&
       ! patch --batch --dry-run --fuzz=0 -R -p1 -d "$LIBCAMERA_SRC" \
        < "$ROOT/libcamera-patch/experimental-ov8856-support.patch" >/dev/null 2>&1; then
        echo "OV8856 support patch matches neither forward nor reverse." >&2
        exit 1
    fi
    echo "PASS: experimental installer syntax and kernel patches validated"
    exit 0
fi

[[ "$ACTION" == install || "$ACTION" == revert ]] || {
    echo "Usage: $0 [install|check|revert]" >&2
    exit 1
}
[[ "$(id -u)" == 0 ]] || { echo "Run with sudo: bash $0 $ACTION" >&2; exit 1; }
[[ "$(cat /sys/class/dmi/id/product_name)" == 'Latitude 7320 Detachable' ]] || {
    echo "Wrong laptop model; nothing changed." >&2
    exit 1
}

if [[ "$ACTION" == revert ]]; then
    [[ -f "$BACKUP/complete" && -f "$BACKUP/board.original" &&
       -f "$BACKUP/sensor.original" && -f "$BACKUP/initrd.original" ]] || {
        echo "No complete backup for $KERNEL." >&2
        exit 1
    }
    restore_originals
    rm -f "$BACKUP/installed"
    echo "Original kernel modules and boot image restored. Reboot to activate them."
    exit 0
fi

[[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] || {
    echo "Run sudo from your desktop user's terminal." >&2
    exit 1
}
if [[ -r /sys/kernel/security/lockdown ]] &&
   ! grep -q '\[none\]' /sys/kernel/security/lockdown; then
    echo "Kernel lockdown is enabled; this unsigned experiment needs module signing first." >&2
    exit 1
fi
if [[ -d "$BACKUP" && ! -f "$BACKUP/complete" &&
      -n "$(find "$BACKUP" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    ARCHIVE="${BACKUP}.incomplete.$(date +%Y%m%d%H%M%S)"
    [[ ! -e "$ARCHIVE" ]] || { echo "Backup archive already exists: $ARCHIVE" >&2; exit 1; }
    mv "$BACKUP" "$ARCHIVE"
    echo "Preserved incomplete backup at $ARCHIVE"
fi
[[ -f "$INITRD" ]] || { echo "Cannot find $INITRD; nothing changed." >&2; exit 1; }
[[ -f "$IPU6_FIRMWARE" ]] || {
    echo "Missing IPU6 firmware: $IPU6_FIRMWARE" >&2
    exit 1
}
command -v dracut >/dev/null
command -v lsinitrd >/dev/null
command -v zstd >/dev/null
command -v xz >/dev/null

BUILD_ROOT="$(mktemp -d "$CAMERA_HOME/.cache/latitude-7320-rear-install.XXXXXX")"
chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$BUILD_ROOT"
runuser -u "$SUDO_USER" -- env XDG_CACHE_HOME="$BUILD_ROOT" \
    bash "$HERE/build-rear-camera.sh"
BUILD="$BUILD_ROOT/latitude-7320-rear-camera"

bash "$HERE/install-rgbir.sh" build
bash "$HERE/install-rgbir.sh" enable

BOARD_TARGET="$(modinfo -n intel_skl_int3472_tps68470)"
SENSOR_TARGET="$(modinfo -n ov8856)"
[[ "$BOARD_TARGET" == "/lib/modules/$KERNEL/"* &&
   "$SENSOR_TARGET" == "/lib/modules/$KERNEL/"* ]] || {
    echo "Unexpected module paths; no kernel modules replaced." >&2
    exit 1
}
if [[ ! -f "$BACKUP/complete" ]]; then
    install -d -m700 "$BACKUP"
    printf '%s\n' "$BOARD_TARGET" > "$BACKUP/board.path"
    printf '%s\n' "$SENSOR_TARGET" > "$BACKUP/sensor.path"
    cp -a "$BOARD_TARGET" "$BACKUP/board.original"
    cp -a "$SENSOR_TARGET" "$BACKUP/sensor.original"
    cp -a "$INITRD" "$BACKUP/initrd.original"
    date -Is > "$BACKUP/complete"
else
    [[ "$(<"$BACKUP/board.path")" == "$BOARD_TARGET" &&
       "$(<"$BACKUP/sensor.path")" == "$SENSOR_TARGET" ]] || {
        echo "The saved rollback modules target different paths; refusing install." >&2
        exit 1
    }
fi
trap 'status=$?; trap - ERR; echo "Install failed; restoring original kernel files." >&2; restore_originals; exit "$status"' ERR

install_module "$BUILD/board/intel_skl_int3472_tps68470.ko" "$BOARD_TARGET"
install_module "$BUILD/sensor/ov8856.ko" "$SENSOR_TARGET"
depmod -a "$KERNEL"
dracut --force --kver "$KERNEL" --install "$IPU6_FIRMWARE"
if ! lsinitrd "$INITRD" | grep -Eq 'intel/ipu/ipu6_fw\.bin(\.zst)?$'; then
    echo "ERROR: generated initrd does not contain the IPU6 firmware." >&2
    restore_originals
    exit 1
fi
printf '%s\n' "$BUILD" > "$BACKUP/installed"
trap - ERR

echo
echo "Experimental rear-camera modules installed for $KERNEL only. Reboot to test."
echo "No running kernel module was unloaded. Existing front-camera tuning is preserved."
echo "After reboot: cam --list"
echo "Rollback: sudo bash $0 revert"
echo "Then reboot again. Do not treat this experiment as kernel-upgrade support."
