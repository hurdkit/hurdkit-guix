#!/usr/bin/env bash
# Read-only graphics checks inside the Linux reference guest. The SSH command
# is deliberately independent of the interactive login shell on tty1.
set -euo pipefail
if [[ "$(id -u)" == 0 ]]; then
    cd /home/peon
    for attempt in {1..30}; do
        [[ -d /run/user/1000 ]] && break
        sleep 1
    done
    exec su peon -c 'HOME=/home/peon USER=peon LOGNAME=peon bash -s'
fi
PATH=/run/current-system/profile/bin:/run/current-system/profile/sbin:$PATH
export PATH
XDG_RUNTIME_DIR=/run/user/$(id -u)
export XDG_RUNTIME_DIR
export XDG_SESSION_TYPE=wayland
export LIBSEAT_BACKEND=seatd
export VK_ICD_FILENAMES=/run/current-system/profile/share/vulkan/icd.d/virtio_icd.x86_64.json

for attempt in {1..30}; do
    WAYLAND_DISPLAY=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s \
        -name 'wayland-*' -printf '%f\n' 2>/dev/null | sort | head -n 1)
    if [[ -n "$WAYLAND_DISPLAY" ]]; then
        NIRI_SOCKET=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s \
            -name "niri.${WAYLAND_DISPLAY}.*.sock" -print -quit)
        export NIRI_SOCKET
        niri msg --json outputs >/dev/null 2>&1 && break
    fi
    sleep 1
done
: "${WAYLAND_DISPLAY:?no Wayland socket found in $XDG_RUNTIME_DIR}"
export WAYLAND_DISPLAY
printf 'WAYLAND_DISPLAY=%s\n' "$WAYLAND_DISPLAY"
niri msg version
niri msg --json outputs
printf '\n=== EGL ===\n'
eglinfo -B
printf '\n=== Vulkan ===\n'
vulkaninfo --summary 2>&1 || true
printf '\n=== glmark2 ===\n'
glmark2-es2-wayland --off-screen --benchmark build:duration=10
printf '\n=== vkcube ===\n'
vkcube_rc=0
timeout --signal=TERM --kill-after=2s 10s vkcube --wsi wayland || vkcube_rc=$?
[[ "$vkcube_rc" == 0 || "$vkcube_rc" == 124 ]] || exit "$vkcube_rc"
