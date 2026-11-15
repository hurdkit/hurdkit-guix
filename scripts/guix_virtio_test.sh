#!/usr/bin/env bash
# Run the upstream virtio-9p matrix in the Guix Hurd guest.
#
# scripts/virtio_test.py owns the actual assertions. This wrapper supplies
# Guix's SSH port, halt semantics, and separately built driver binaries. It
# deliberately does not reuse the Debian image or install Debian packages.
#
# Build the inputs first:
#   guix build --target=x86_64-pc-gnu -f guix/virtio-9p.scm
#   guix build --target=x86_64-pc-gnu -f guix/9pfs.scm
#
# The guest runs from a disposable overlay. On failure it is left running,
# with its serial log and QEMU monitor available for inspection.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export GUIX_DIR="${GUIX_DIR:-$REPO_ROOT/img/guix/virtio-test}"
export GUIX_SSH_PORT="${GUIX_SSH_PORT:-2231}"
export GUIX_BOOT_ATTEMPTS="${GUIX_BOOT_ATTEMPTS:-2}"
export GUIX_BOOT_TIMEOUT="${GUIX_BOOT_TIMEOUT:-180}"
export SSH_HOST="${SSH_HOST:-127.0.0.1}"
export SSH_PORT="$GUIX_SSH_PORT"
export SSH_KEY="${SSH_KEY:-${SSH_KEY_DIR:-$REPO_ROOT/img/keys}/root_ed25519}"
export SHARE="${SHARE:-$GUIX_DIR/share}"
export MOUNT_TAG="${MOUNT_TAG:-hostshare}"
export QEMU_LOG="$GUIX_DIR/serial.log"
export GDB="${GDB:-0}"
export VIRTIO_ADDR="${VIRTIO_ADDR-0x5}"
export VIRTIO_GDB_COMMAND="${VIRTIO_GDB_COMMAND:-gdb}"
export VIRTIO_HALT_COMMAND="${VIRTIO_HALT_COMMAND:-halt}"
export VIRTIO_POWEROFF_TIMEOUT="${VIRTIO_POWEROFF_TIMEOUT:-60}"
GUIX="${GUIX:-guix}"
MODE="${MODE:-main}"
VIRTIO_STORE="${VIRTIO_STORE:-}"
P9FS_STORE="${P9FS_STORE:-}"
MONITOR_SOCKET="${XDG_RUNTIME_DIR:-/tmp}/hurdkit-guix-${GUIX_SSH_PORT}.monitor"
FAILED=0
GUEST_STARTED=0
SUCCESS=0

need_guest() {
    GUIX_DIR="$GUIX_DIR" GUIX_SSH_PORT="$GUIX_SSH_PORT" \
        SSH_KEY_DIR="$(dirname "$SSH_KEY")" GUIX="$GUIX" \
        bash "$SCRIPT_DIR/guix_vm.sh" "$@"
}

guest_start() {
    if (( $# )); then
        # Positional parameters preserve each QEMU option across the script
        # boundary. Unlike Bash arrays, they need no environment trick.
        need_guest start -- "$@"
    else
        need_guest start
    fi
}

if [[ -e "$GUIX_DIR" ]]; then
    echo "guix-virtio-test: $GUIX_DIR already exists; choose an unused diagnostic directory" >&2
    exit 1
fi
[[ -f "$REPO_ROOT/img/guix/hurd64.base.qcow2" ]] || {
    echo "guix-virtio-test: build the ordinary Guix base first (make guix-image)" >&2
    exit 1
}
[[ -f "$SSH_KEY" ]] || {
    echo "guix-virtio-test: missing root key $SSH_KEY" >&2
    exit 1
}
refresh_serial_log() {
    local latest
    latest="$(find "$GUIX_DIR" -maxdepth 1 -type f -name 'serial-[0-9]*.log' \
        -printf '%f\n' | sort -V | tail -n 1)"
    if [[ -n "$latest" ]]; then
        QEMU_LOG="$GUIX_DIR/$latest"
        export QEMU_LOG
    fi
}

cleanup() {
    if (( ! SUCCESS )); then
        FAILED=1
        if (( GUEST_STARTED )); then
            cat >&2 <<EOF
guix-virtio-test: FAILED; guest left running for diagnosis.
  serial: $QEMU_LOG
  monitor: $MONITOR_SOCKET
  SSH: ssh -i $SSH_KEY -p $GUIX_SSH_PORT root@$SSH_HOST
  reuse the matrix with MODE=$MODE REUSE=1 $0
  stop only after diagnosis: GUIX_DIR="$GUIX_DIR" GUIX_SSH_PORT="$GUIX_SSH_PORT" bash "$SCRIPT_DIR/guix_vm.sh" stop
EOF
        else
            echo "guix-virtio-test: FAILED; guest stopped; logs retained in $GUIX_DIR" >&2
        fi
        exit 1
    fi
    need_guest stop >/dev/null 2>&1 || true
    # Only the synthetic diagnostic directory is removed. The base symlink's
    # target and the store-built 9pfs package are not touched.
    rm -rf "$GUIX_DIR"
}
trap cleanup EXIT

mkdir -p "$GUIX_DIR/tmp" "$SHARE"
# This is a diagnostic image only; it never replaces img/guix/hurd64.base.qcow2.
ln -s "$REPO_ROOT/img/guix/hurd64.base.qcow2" "$GUIX_DIR/hurd64.base.qcow2"
if [[ -z "$P9FS_STORE" ]]; then
    P9FS_STORE="$($GUIX build --target=x86_64-pc-gnu -f "$REPO_ROOT/guix/9pfs.scm")"
fi
if [[ -z "$VIRTIO_STORE" ]]; then
    VIRTIO_STORE="$($GUIX build --target=x86_64-pc-gnu -f "$REPO_ROOT/guix/virtio-9p.scm")"
fi
export P9FS_BIN="$P9FS_STORE/bin/9pfs"
export VIRTIO_9P_BIN="$VIRTIO_STORE/bin/virtio-9p"
[[ -x "$P9FS_BIN" && -x "$VIRTIO_9P_BIN" ]] || {
    echo "guix-virtio-test: Guix-built driver binaries are missing" >&2
    exit 1
}
printf 'from host\n' > "$SHARE/host-seed.txt"

if [[ "${REUSE:-0}" == 1 ]]; then
    need_guest status
    GUEST_STARTED=1
else
    # Keep the virtio device optional. Ordinary guix-start never gets it.
    # The upstream Debian default uses a separate IRQ on i440fx. Verify the
    # q35 topology before treating that same address as an IRQ control here.
    guest_start \
        -fsdev "local,id=virtfs0,path=$SHARE,security_model=none" \
        -device "virtio-9p-pci,fsdev=virtfs0,mount_tag=$MOUNT_TAG,disable-legacy=off${VIRTIO_ADDR:+,addr=$VIRTIO_ADDR}"
    GUEST_STARTED=1
fi
refresh_serial_log

# The upstream harness remains authoritative for all mount and I/O checks.
if ! python3 "$SCRIPT_DIR/virtio_test.py" "$MODE"; then
    FAILED=1
    exit 1
fi
if [[ "$MODE" == main ]]; then
    # Guix's halt stops Mach and leaves QEMU running. The wrapper's stop
    # waits for the serial completion marker before removing the overlay.
    # A forced stop is a failed lifecycle gate even if the matrix passed.
    set +e
    need_guest stop
    stop_rc=$?
    refresh_serial_log
    set -e
    GUEST_STARTED=0
    (( stop_rc == 0 )) || {
        echo "guix-virtio-test: matrix passed, but shutdown failed; see $QEMU_LOG" >&2
        exit "$stop_rc"
    }
fi

SUCCESS=1
echo "guix-virtio-test: matrix and shutdown completed; no-device lifecycle control remains a separate boot."
