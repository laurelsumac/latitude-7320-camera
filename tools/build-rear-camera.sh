#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="${XDG_CACHE_HOME:-$HOME/.cache}/latitude-7320-rear-camera"
KERNEL="$(uname -r)"
SOURCES=(/usr/src/ipu6-drivers-*/drivers/media/i2c/ov8856.c)

[[ "$(cat /sys/class/dmi/id/product_name)" == 'Latitude 7320 Detachable' ]] || {
    echo "This experiment is only for the Latitude 7320 Detachable." >&2
    exit 1
}
[[ "${#SOURCES[@]}" == 1 && -f "${SOURCES[0]}" ]] || {
    echo "Expected exactly one installed IPU6 OV8856 driver source." >&2
    exit 1
}
[[ ! -e "$WORK" ]] || {
    echo "Build directory already exists: $WORK" >&2
    echo "Set XDG_CACHE_HOME to a fresh directory to preserve the previous build." >&2
    exit 1
}

mkdir -p "$WORK/board" "$WORK/sensor"
cp "$ROOT/module/"*.c "$ROOT/module/"*.h "$ROOT/module/Makefile" "$WORK/board/"
cp "${SOURCES[0]}" "$WORK/sensor/ov8856.c"
cp "$ROOT/kernel-patches/ov8856-dell7320-power.h" "$WORK/sensor/"
printf 'obj-m += ov8856.o\n' > "$WORK/sensor/Makefile"
patch --batch --fuzz=0 -p1 -d "$WORK/board" < "$ROOT/kernel-patches/experimental-ov8856-board-data.patch"
patch --batch --fuzz=0 -p1 -d "$WORK/sensor" < "$ROOT/kernel-patches/experimental-ov8856-power.patch"
patch --batch --fuzz=0 -p1 -d "$WORK/sensor" < "$ROOT/kernel-patches/experimental-ov8856-selection.patch"
make -C "/lib/modules/$KERNEL/build" M="$WORK/board" modules
make -C "/lib/modules/$KERNEL/build" M="$WORK/sensor" modules
printf '\nBuilt experimental modules for %s in %s\n' "$KERNEL" "$WORK"
echo "No modules were installed or loaded."
