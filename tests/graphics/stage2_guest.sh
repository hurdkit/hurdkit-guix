#!/bin/sh
# The guest's part of the stage 2 gate: libwayland's tests, the rendering
# programs, and the compositor's CPU time while idle. The host compares
# the frames in the result directory with its reference.
#
# Usage: stage2_guest.sh RESULT-DIRECTORY
set -eu
out=$1
bin=$(dirname "$0")
rm -rf "$out"
mkdir -p "$out"
# The fixed tmpfs: Wayland's shared-memory buffers live here.
export XDG_RUNTIME_DIR=/dev/shm/hurdkit-stage2-runtime
rm -rf "$XDG_RUNTIME_DIR"
mkdir -m 700 "$XDG_RUNTIME_DIR"
echo 'libwayland tests'
"$bin/wayland_tests.sh"
echo 'rendering'
"$bin/ppm-test" "$out"
OUT="$out" "$bin/smoke.sh" "$bin"
echo 'idle compositor'
OUT="$out/idle" "$bin/wl-test-server" --socket idle >"$out/idle.log" 2>&1 &
pid=$!
while ! grep -q '^READY ' "$out/idle.log"; do
    kill -0 "$pid"
    sleep 1
done
before=$(awk '{print $14 + $15}' "/proc/$pid/stat")
sleep 10
after=$(awk '{print $14 + $15}' "/proc/$pid/stat")
kill "$pid"
wait "$pid" 2>/dev/null || true
# Clock ticks of CPU time in ten seconds: an event loop that spins shows
# up as hundreds.
echo "$((after - before))" >"$out/idle.ticks"
