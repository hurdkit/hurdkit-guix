#!/usr/bin/env bash
# The niri plan's stage-2 gate. It renders the reference frames on this
# machine, builds guix/hurd64-wayland.scm, boots it in its own directory
# and port, runs libwayland's tests and the same programs in the guest,
# and compares the guest's frames with the reference.
#
# "stage2_check.sh reference" stops after the reference: no guest.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GUIX_DIR="${GUIX_DIR:-$ROOT/img/guix-wayland}"
export GUIX_SSH_PORT="${GUIX_SSH_PORT:-2227}"
export GUIX_OS="$ROOT/guix/hurd64-wayland.scm"
export GUIX_MEMORY="${GUIX_MEMORY:-3072}"
# The guest boots gnumach-hurdkit-smp; give it as many processors as that
# kernel is built for.
export GUIX_CPUS="${GUIX_CPUS:-2}"
GUIX="${GUIX:-guix}"
# Frames per client, and the longest a client may take for them in the guest.
FRAMES="${STAGE2_FRAMES:-60}"
MAX_SECONDS="${STAGE2_MAX_SECONDS:-30}"
TEST_TIMEOUT="${STAGE2_TEST_TIMEOUT:-1200}"
REFERENCE="$GUIX_DIR/reference"
RESULTS="$GUIX_DIR/results"
GUEST_RESULTS=/tmp/hurdkit-stage2-results
status=0
started=0
guix_vm() { bash "$ROOT/scripts/guix_vm.sh" "$@"; }
ppm() { tclsh "$ROOT/scripts/ppm_check.tcl" "$@"; }
stop_guest() {
    if ((started)); then
        started=0
        guix_vm stop || status=1
    fi
}
trap stop_guest EXIT
check() {
    echo "# $*"
    "$@" || { echo "FAIL: $*"; status=1; }
}
# The frames that smoke.sh keeps of every client.
kept=(1 $(( (FRAMES + 1) / 2 )) "$FRAMES")
frame() { echo "$1/$2/wl-$2-client-frame-$3.ppm"; }

# The scene of egl-triangle and wl-egl-client: its background, and the
# colour next to each vertex of the triangle.
scene() {
    ppm region "$1" 10 10 10 10 0a0f1a 100 2 &&
        ppm region "$1" 192 85 1 1 a4391f 100 8 &&
        ppm region "$1" 448 85 1 1 39a41f 100 8 &&
        ppm region "$1" 320 390 1 1 2020bc 100 8
}
# What must hold for a set of frames, here and in the guest.
frames_valid() {
    local dir="$1" kind number
    check grep -q softpipe "$dir/renderer.txt"
    check scene "$dir/triangle.ppm"
    for kind in shm egl; do
        for number in "${kept[@]}"; do
            check test "$(ppm dimensions "$(frame "$dir" "$kind" "$number")")" = 640x480
        done
    done
    # The gradient of wl-shm-client moves with every frame.
    check ppm changed "$(frame "$dir" shm "${kept[0]}")" \
        "$(frame "$dir" shm "${kept[2]}")" 20
    check scene "$(frame "$dir" egl "${kept[2]}")"
}

mkdir -p "$GUIX_DIR"
echo "# reference frames, rendered on this machine"
tests="$("$GUIX" build --load-path="$ROOT/guix/modules" hurdkit-graphics-tests)" || exit 1
rm -rf "$REFERENCE"
mkdir -p "$REFERENCE"
check "$tests/bin/ppm-test" "$REFERENCE"
# The same rasteriser as in the guest.
check env GALLIUM_DRIVER=softpipe FRAMES="$FRAMES" OUT="$REFERENCE" \
    "$tests/bin/smoke.sh" "$tests/bin"
frames_valid "$REFERENCE"
if (( status != 0 )) || [[ "${1:-}" == reference ]]; then
    exit "$status"
fi

# Refuse a port that another guest uses before the image is built.
if ps -eo args | grep -E 'qemu-system.*hostfwd=[^ ]*:'"$GUIX_SSH_PORT"'-' | grep -v grep; then
    echo "stage2-check: port $GUIX_SSH_PORT is in use" >&2
    exit 1
fi
guix_vm image || exit 1
guix_vm start || exit 1
started=1
echo "# guest"
guix_vm ssh root env FRAMES="$FRAMES" timeout "$TEST_TIMEOUT" \
    stage2_guest.sh "$GUEST_RESULTS"
rc=$?
# Fetch what there is, also after a failure, then halt the guest.
rm -rf "$RESULTS"
mkdir -p "$RESULTS"
guix_vm ssh root tar -C "$GUEST_RESULTS" --exclude=runtime -cf - . |
    tar -C "$RESULTS" -xf - || status=1
stop_guest
if (( rc != 0 )); then
    echo "FAIL: stage2_guest.sh (exit $rc)"
    exit 1
fi

frames_valid "$RESULTS"
# The shared-memory frames are computed by the client: they are equal.
# The rendered ones may differ where the rasteriser rounds differently.
check ppm differs "$RESULTS/triangle.ppm" "$REFERENCE/triangle.ppm" 1
for number in "${kept[@]}"; do
    check ppm differs "$(frame "$RESULTS" shm "$number")" \
        "$(frame "$REFERENCE" shm "$number")" 0
    check ppm differs "$(frame "$RESULTS" egl "$number")" \
        "$(frame "$REFERENCE" egl "$number")" 1
done
for kind in shm egl; do
    check test "$(cat "$RESULTS/$kind.seconds")" -le "$MAX_SECONDS"
done
# Under one percent of a CPU while idle, at a hundred ticks a second.
check test "$(cat "$RESULTS/idle.ticks")" -lt 10
exit "$status"
