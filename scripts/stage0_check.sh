#!/usr/bin/env bash
# Stage 0 live gate. Run from the pinned goonix shell; no Python tooling.
# Each case uses a disposable overlay and leaves the guest stopped.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1
ARTIFACT_DIR="${STAGE0_ARTIFACT_DIR:-$REPO_ROOT/img/stage0}"
mkdir -p "$ARTIFACT_DIR"
STAGE0_GPUS="${STAGE0_GPUS:-amd nvidia}"
STAGE0_VENUS_GPUS="${STAGE0_VENUS_GPUS:-amd nvidia}"
GUIX_OS="${GUIX_OS:-guix/hurd64.scm}"
export GUIX_OS
failures=0
hurd_started=0
linux_started=0
cleanup() {
    if (( linux_started )); then
        make linux-ref-stop > "$ARTIFACT_DIR/cleanup-linux-stop.log" 2>&1 || true
    fi
    if (( hurd_started )); then
        make guix-stop > "$ARTIFACT_DIR/cleanup-hurd-stop.log" 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM
record() {
    local status="$1" description="$2"
    printf '%s: %s\n' "$status" "$description"
    [[ "$status" == PASS ]] || failures=$((failures + 1))
}
run_logged() {
    local log="$1"; shift
    "$@" > "$log" 2>&1
}

[[ "$(guix --version | head -n 1)" == *goonix* ]] || {
    echo 'stage0-check: run inside nix develop ./nix#guix' >&2
    exit 1
}

if run_logged "$ARTIFACT_DIR/hurd-start.log" make guix-start GUIX_GPU=none; then
    hurd_started=1
    cp img/guix/screen.ppm "$ARTIFACT_DIR/hurd-screen.ppm" 2>/dev/null || true
    if run_logged "$ARTIFACT_DIR/hurd-screenshot.log" make guix-screenshot; then
        cp img/guix/screen.ppm "$ARTIFACT_DIR/hurd-screen.ppm"
        if dimensions=$(tclsh scripts/ppm_check.tcl dimensions img/guix/screen.ppm) &&
            [[ "$dimensions" == 640x400 || "$dimensions" == 720x400 ]]; then
            record PASS "Hurd boots with the default GPU setting ($dimensions)"
        else
            record FAIL "Hurd screenshot has unexpected dimensions ($dimensions)"
        fi
    else
        record FAIL 'Hurd QMP screenshot'
    fi
else
    record FAIL 'Hurd boot'
fi
if (( hurd_started )); then
    if run_logged "$ARTIFACT_DIR/hurd-stop.log" make guix-stop; then
        record PASS 'Hurd clean shutdown'
        hurd_started=0
    else
        record FAIL 'Hurd clean shutdown'
    fi
fi

for gpu in $STAGE0_GPUS; do
    case "$gpu" in amd) vendor='AMD' ;; nvidia) vendor='NVIDIA' ;; *) record FAIL "unknown GPU $gpu"; continue ;; esac
    for path in virgl venus; do
        [[ "$path" == virgl || " $STAGE0_VENUS_GPUS " == *" $gpu "* ]] || continue
        name="$path-$gpu"
        run_dir="$ARTIFACT_DIR/$name"
        mkdir -p "$run_dir"
        trace="$run_dir/virtio-gpu.trace"
        idle_trace="$run_dir/idle.trace"
        benchmark_trace="$run_dir/benchmark.trace"
        rm -f "$trace" "$idle_trace" "$benchmark_trace"
        started=0
        if run_logged "$run_dir/start.log" make linux-ref-start \
            GUIX_GPU="$path" GUIX_DISPLAY=egl-headless GUIX_HOST_GPU="$gpu" \
            GUIX_TRACE='virtio_gpu_cmd_*' GUIX_TRACE_FILE="$trace"; then
            started=1
            linux_started=1
            # Ten seconds of the idle desktop: what the trace gains while
            # nothing changes on the screen.
            idle_start="$(stat -c %s "$trace" 2>/dev/null || echo 0)"
            sleep 10
            tail -c +"$((idle_start + 1))" "$trace" > "$idle_trace" 2>/dev/null || true
            run_logged "$run_dir/session.log" make linux-ref-ssh < scripts/linux-ref-session.sh
            if [[ "$path" == virgl ]] && grep -Eq "GL_RENDERER:.*virgl.*$vendor" "$run_dir/session.log"; then
                record PASS "$name guest renderer"
            elif [[ "$path" == venus ]] && grep -Eq "deviceName.*Virtio-GPU Venus.*$vendor" "$run_dir/session.log" &&
                grep -Eq "Selected GPU.*Virtio-GPU Venus.*$vendor" "$run_dir/session.log"; then
                record PASS "$name guest Vulkan renderer"
            else
                record FAIL "$name guest renderer"
            fi
            if grep -q 'glmark2 Score:' "$run_dir/session.log"; then
                record PASS "$name glmark2"
            else
                record FAIL "$name glmark2"
            fi
            if run_logged "$run_dir/screenshot-before.log" make linux-ref-screenshot &&
                cp img/guix-linux/screen.ppm "$run_dir/before.ppm" &&
                grep -q 'Virtual-1' "$run_dir/session.log" &&
                grep -Eq '^[0-9]+x[0-9]+$' <(tclsh scripts/ppm_check.tcl dimensions "$run_dir/before.ppm"); then
                record PASS "$name compositor IPC and screenshot"
            else
                record FAIL "$name compositor screenshot"
            fi
            if run_logged "$run_dir/input.log" make linux-ref-qmp GUIX_QMP_ARGS='key super+t'; then
                sleep 3
                run_logged "$run_dir/screenshot-after.log" make linux-ref-screenshot
                cp img/guix-linux/screen.ppm "$run_dir/after.ppm"
                # The foot window covers part of the screen.
                if tclsh scripts/ppm_check.tcl changed "$run_dir/after.ppm" "$run_dir/before.ppm" 5 \
                    > "$run_dir/difference.log" &&
                    run_logged "$run_dir/windows.log" make linux-ref-ssh < scripts/linux-ref-windows.sh &&
                    grep -q '"app_id":"foot"' "$run_dir/windows.log"; then
                    record PASS "$name QMP input opens a foot window"
                else
                    record FAIL "$name QMP input"
                fi
            else
                record FAIL "$name QMP input"
            fi
        else
            record FAIL "$name boot"
        fi
        if (( started )); then
            if run_logged "$run_dir/stop.log" make linux-ref-stop; then
                record PASS "$name clean shutdown"
                linux_started=0
            else
                record FAIL "$name clean shutdown"
            fi
        fi
        if [[ -f "$trace" ]]; then
            # The whole run: boot, the session checks and glmark2.
            cp "$trace" "$benchmark_trace"
            for sample in "$trace" "$idle_trace" "$benchmark_trace"; do
                [[ -f "$sample" ]] || continue
                awk '/virtio_gpu_cmd_/ {counts[$1]++} END {for (event in counts) print event, counts[event]}' \
                    "$sample" | sort > "$sample.counts.txt"
            done
        fi
    done
done
(( failures == 0 ))
