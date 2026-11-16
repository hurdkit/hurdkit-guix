#!/usr/bin/env bash
# Build, boot and test the stage 1 Hurd platform guest.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/img/guix-platform"
PORT=2226
export GUIX_DIR="$DIR" GUIX_SSH_PORT="$PORT" GUIX_OS="$ROOT/guix/hurd64-platform.scm"
export GUILE_AUTO_COMPILE=0
status=0
started=0
stop_guest() {
    if ((started)); then
        started=0
        bash "$ROOT/scripts/guix_vm.sh" stop || status=1
    fi
}
trap stop_guest EXIT
bash "$ROOT/scripts/guix_vm.sh" image || exit 1
bash "$ROOT/scripts/guix_vm.sh" start || exit 1
started=1
run() {
    echo "+ $*" >&2
    local output
    output="$(bash "$ROOT/scripts/guix_vm.sh" ssh root "$@")" || {
        printf '%s\n' "$output"
        return 1
    }
    printf '%s\n' "$output"
    if [[ "$*" == *shm-unlink* || "$*" == *hurdkit-eventfd* ||
          "$*" == *hurdkit-epoll* || "$*" == *hurdkit-timerfd* ||
          "$*" == *hurdkit-signalfd* || "$*" == *hurdkit-rust-evloop* ]]; then
        if grep -E '^(not ok|Bail out!)|^ok .*# *SKIP' <<<"$output"; then
            return 1
        fi
        grep -q '^TAP version 13' <<<"$output"
    fi
}
run shm-unlink /dev/shm || status=1
run shm-unlink --anon || status=1
run shm-unlink /tmp || status=1
run tmpfs-io /dev/shm || status=1
# This includes the documented POSIX truncation-boundary regression. If it
# fails, retain that failure rather than silently skipping the assertion.
run tmpfs-lifetime /dev/shm 100 || status=1
for name in eventfd epoll timerfd signalfd; do
    run "hurdkit-$name" || status=1
done
run hurdkit-rust-hello || status=1
run hurdkit-rust-evloop || status=1
exit "$status"
