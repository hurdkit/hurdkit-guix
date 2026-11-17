#!/bin/sh
# Render the stage 2 frames without a display: surfaceless EGL, then a
# shared-memory client and an EGL client against the test compositor. The
# same script runs on Linux, for the reference, and in the Hurd guest.
#
# Usage: OUT=DIRECTORY smoke.sh BIN-DIRECTORY
# Of every client's FRAMES frames, the first, a middle one and the last
# are kept in OUT/shm and OUT/egl; OUT/KIND.seconds is the client's run time.
set -eu
bin=$1
out=$OUT
frames=${FRAMES:-60}
kept="1 $(( (frames + 1) / 2 )) $frames"
server_pid=
cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$out"
: "${XDG_RUNTIME_DIR:=$out/runtime}"
export XDG_RUNTIME_DIR
[ -d "$XDG_RUNTIME_DIR" ] || mkdir -m 700 "$XDG_RUNTIME_DIR"
export LIBGL_ALWAYS_SOFTWARE=1
EGL_PLATFORM=surfaceless "$bin/egl-triangle" \
    --output "$out/triangle.ppm" --renderer-file "$out/renderer.txt"
for kind in shm egl; do
    log="$out/$kind.log"
    OUT="$out/$kind" CLIENT_NAME="wl-$kind-client" "$bin/wl-test-server" \
        --socket "hurdkit-$kind" --frames "$frames" >"$log" 2>&1 &
    server_pid=$!
    ready_deadline=$(( $(date +%s) + 30 ))
    while ! grep -q '^READY ' "$log"; do
        if ! kill -0 "$server_pid" 2>/dev/null; then cat "$log"; exit 1; fi
        if [ "$(date +%s)" -ge "$ready_deadline" ]; then
            echo "timed out waiting for the $kind compositor" >&2
            exit 1
        fi
        sleep 1
    done
    started=$(date +%s)
    set +e
    WAYLAND_DISPLAY="hurdkit-$kind" "$bin/wl-$kind-client" --frames "$frames"
    rc=$?
    set -e
    echo $(( $(date +%s) - started )) >"$out/$kind.seconds"
    if [ "$rc" -ne 0 ]; then kill "$server_pid" 2>/dev/null || true; fi
    wait "$server_pid"
    server_pid=
    [ "$rc" -eq 0 ]
    # The compositor wrote one file for every commit.
    number=0
    for frame in "$out/$kind"/*.ppm; do
        [ -f "$frame" ] || exit 1
        number=$((number + 1))
    done
    [ "$number" -eq "$frames" ]
    for frame in "$out/$kind"/*.ppm; do
        number=${frame##*-frame-}
        case " $kept " in
            *" ${number%.ppm} "*) ;;
            *) rm -f "$frame" ;;
        esac
    done
done
