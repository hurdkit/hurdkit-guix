#!/usr/bin/env bash
# List niri windows through the running compositor's IPC socket.
set -euo pipefail
if [[ "$(id -u)" == 0 ]]; then
    cd /home/peon
    exec su peon -c 'HOME=/home/peon USER=peon LOGNAME=peon bash -s'
fi
XDG_RUNTIME_DIR=/run/user/$(id -u)
export XDG_RUNTIME_DIR
export WAYLAND_DISPLAY=wayland-1
NIRI_SOCKET=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s \
    -name "niri.${WAYLAND_DISPLAY}.*.sock" -print -quit)
export NIRI_SOCKET
: "${NIRI_SOCKET:?no niri IPC socket found}"
exec niri msg --json windows
