#!/usr/bin/env bash
# The niri plan's stage-1 gate: build guix/hurd64-platform.scm, boot it in
# its own directory and port, and run the platform tests in it. A TAP test
# fails on a "not ok", a missing plan, a nonzero exit, or when it runs
# longer than STAGE1_TEST_TIMEOUT seconds. Skips (documented platform
# differences) are listed, not failed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GUIX_DIR="${GUIX_DIR:-$ROOT/img/guix-platform}"
export GUIX_SSH_PORT="${GUIX_SSH_PORT:-2226}"
export GUIX_OS="$ROOT/guix/hurd64-platform.scm"
# The guest boots gnumach-hurdkit-smp; give it as many processors as that
# kernel is built for.
export GUIX_CPUS="${GUIX_CPUS:-2}"
TEST_TIMEOUT="${STAGE1_TEST_TIMEOUT:-600}"
status=0
started=0
guix_vm() { bash "$ROOT/scripts/guix_vm.sh" "$@"; }
stop_guest() {
    if ((started)); then
        started=0
        guix_vm stop || status=1
    fi
}
trap stop_guest EXIT
guix_vm image || exit 1
guix_vm start || exit 1
started=1

# run_tap COMMAND...: run COMMAND in the guest and check its TAP output.
run_tap() {
    local output rc
    echo "# $*"
    output="$(guix_vm ssh root timeout "$TEST_TIMEOUT" "$@" 2>&1)"
    rc=$?
    printf '%s\n' "$output"
    if (( rc != 0 )) || ! grep -q '^1\.\.[1-9]' <<<"$output" ||
        grep -Eq '^not ok|^Bail out!' <<<"$output"; then
        echo "FAIL: $* (exit $rc)"
        status=1
    elif grep -q '# *SKIP' <<<"$output"; then
        echo "PASS: $* (skipped: $(grep -c '# *SKIP' <<<"$output"))"
    else
        echo "PASS: $*"
    fi
}

# tmpfs: /dev/shm is the fixed tmpfs; /tmp (ext2) is the control.
run_tap tmpfs-shm /dev/shm 100
run_tap tmpfs-shm /tmp 20
for name in eventfd epoll timerfd signalfd; do
    run_tap "hurd-epoll-shim-test-$name"
done
# The hello program prints one line, not TAP.
if [[ "$(guix_vm ssh root hurdkit-rust-hello)" != "hurdkit rust hello" ]]; then
    echo "FAIL: hurdkit-rust-hello"
    status=1
fi
run_tap hurdkit-rust-evloop
stop_guest
exit "$status"
