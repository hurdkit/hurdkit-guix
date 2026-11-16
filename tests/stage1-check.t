#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
check() {
    local description=$1; shift
    if "$@"; then echo "ok - $description"; else
        echo "not ok - $description"; failures=$((failures + 1));
    fi
}
check 'stage1 check uses a separate platform guest' \
    grep -q 'GUIX_OS=.*hurd64-platform.scm' "$ROOT/scripts/stage1_check.sh"
check 'stage1 check runs tmpfs unlink and anonymous tests' \
    bash -c 'grep -q "shm-unlink /dev/shm" "$1/scripts/stage1_check.sh" && grep -q "shm-unlink --anon" "$1/scripts/stage1_check.sh"' _ "$ROOT"
check 'stage1 check passes tmpfs lifetime arguments through SSH' \
    grep -q '^run tmpfs-lifetime /dev/shm 100' "$ROOT/scripts/stage1_check.sh"
check 'stage1 check runs all shim TAP suites' \
    grep -q 'for name in eventfd epoll timerfd signalfd' "$ROOT/scripts/stage1_check.sh"
check 'stage1 check runs the Rust hello and event-loop TAP tests' \
    bash -c 'grep -q "hurdkit-rust-hello" "$1/scripts/stage1_check.sh" && grep -q "hurdkit-rust-evloop" "$1/scripts/stage1_check.sh"' _ "$ROOT"
check 'stage1 check rejects TAP failures and skips' \
    bash -c 'grep -q "Bail out" "$1/scripts/stage1_check.sh" && grep -q "SKIP" "$1/scripts/stage1_check.sh"' _ "$ROOT"
check 'stage1 check stops its guest on both paths' \
    grep -q 'trap.*stop' "$ROOT/scripts/stage1_check.sh"
check 'stage1 cleanup runs only once' \
    bash -c 'grep -q "started=0" "$1/scripts/stage1_check.sh" && ! grep -q "status=1.*status=1" "$1/scripts/stage1_check.sh"' _ "$ROOT"
check 'make exposes the stage1 gate' grep -q '^stage1-check:' "$ROOT/guix.mk"
exit "$failures"
