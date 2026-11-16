#!/usr/bin/env bash
# Run upstream's balloon or blk assertions in the Guix Hurd lifecycle.
# The common matrix checks guest behavior and QEMU device-model traces;
# guix_vm.sh supplies the overlay, SSH, monitor and clean Mach shutdown.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE="${1:?usage: guix_virtio_device_test.sh balloon|blk}"
case "$DEVICE" in
    balloon) NAME=virtio-balloon-test; TRACE=virtio_balloon; DEVICE_ARG="virtio-balloon-pci,disable-legacy=off,addr=0x5" ;;
    blk) NAME=virtio-blk-test; TRACE=virtio_blk; DEVICE_ARG="virtio-blk-pci,drive=vd0,disable-legacy=off,addr=0x5" ;;
    *) echo "$0: expected balloon or blk" >&2; exit 2 ;;
esac
DIR="$ROOT/img/guix-$NAME"
PORT="${GUIX_SSH_PORT:-2232}"
export GUIX_DIR="$DIR" GUIX_SSH_PORT="$PORT"
QEMU_SYSTEM="${QEMU_SYSTEM:-qemu-system-x86_64}"
export GUIX_OS="$ROOT/guix/hurd64-virtio.scm" GUIX_MEMORY="${RAM_MB:-2048}"
export SSH_KEY_DIR="$ROOT/img/keys" SSH_HOST=127.0.0.1
export SSH_PORT="$PORT" SSH_KEY="$SSH_KEY_DIR/root_ed25519"
export RAM_MB="${RAM_MB:-2048}" REUSE="${REUSE:-0}" GDB="${GDB:-0}"
export VIRTIO_GDB_COMMAND="${VIRTIO_GDB_COMMAND:-gdb}"
export VIRTIO_HALT_COMMAND=halt VIRTIO_NO_POWEROFF=1 VIRTIO_NO_SETSID=1
export VIRTIO_MONITOR_SOCKET="${XDG_RUNTIME_DIR:-/tmp}/hurdkit-guix-${PORT}.monitor"
started=0
status=0
stop_guest() {
    if ((started)); then
        started=0
        bash "$ROOT/scripts/guix_vm.sh" stop || status=1
    fi
}
trap stop_guest EXIT

bash "$ROOT/scripts/guix_vm.sh" image || exit 1
if [[ "$REUSE" == 1 ]]; then
    bash "$ROOT/scripts/guix_vm.sh" status || exit 1
else
    rm -f "$DIR/serial-1.log" "$DIR/serial.log"
fi
mkdir -p "$DIR"
export QEMU_LOG="$DIR/device.trace"

extra=()
if [[ "$DEVICE" == blk ]]; then
    TEST_DISK="$DIR/test-disk.img"
    if [[ "$REUSE" != 1 || ! -f "$TEST_DISK" ]]; then
        python3 "$ROOT/scripts/virtio_blk_test.py" seed "$TEST_DISK" "${DISK_MB:-64}" || exit 1
    fi
    extra=(-drive "if=none,id=vd0,file=$TEST_DISK,format=raw,cache=writeback")
else
    TEST_DISK=""
fi

trace_args=()
while IFS= read -r event; do
    trace_args+=(-trace "enable=$event")
done < <("$QEMU_SYSTEM" -trace help | grep "^${TRACE}_")
((${#trace_args[@]} > 0)) || { echo "$0: no ${TRACE} QEMU trace events" >&2; exit 1; }
rm -f "$QEMU_LOG"
if [[ "$REUSE" != 1 ]]; then
    bash "$ROOT/scripts/guix_vm.sh" start -- \
        "${trace_args[@]}" -D "$QEMU_LOG" \
        "${extra[@]}" -device "$DEVICE_ARG" || exit 1
fi
started=1
# QEMU_LOG names the device trace; the VM's serial log stays in serial-N.log.
# The common matrix reads both, so device-model evidence need not share a file.
store="$(guix build --target=x86_64-pc-gnu -L "$ROOT/guix/modules" hurdkit-virtio)" || exit 1
if [[ "$DEVICE" == balloon ]]; then
    export VIRTIO_BALLOON_BIN="$store/bin/virtio-balloon"
    python3 "$ROOT/scripts/virtio_balloon_test.py" "${MODE:-main}" || status=1
else
    export VIRTIO_BLK_BIN="$store/bin/virtio-blk"
    export VBLK_CLIENT_BIN="$store/bin/vblk-client"
    export TEST_DISK DISK_MB="${DISK_MB:-64}"
    python3 "$ROOT/scripts/virtio_blk_test.py" "${MODE:-main}" || status=1
fi
stop_guest
exit "$status"
