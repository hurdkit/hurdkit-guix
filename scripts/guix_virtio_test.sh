#!/usr/bin/env bash
# Run the virtio driver test matrices in the Guix GNU/Hurd guest.
#
# Usage: guix_virtio_test.sh 9p|balloon|blk|net
#
# Drivers and matrices are Guix packages at pinned commits, see
# (hurdkit packages virtio): this script never runs the scripts of the
# working tree, and what it passes to a matrix is what the pinned one
# expects. It boots guix/hurd64-drivers.scm with the device and its QEMU
# trace events, builds the driver binaries, and hands both to the matrix.
#
# Environment:
#   REUSE=1        run the matrix against the guest that a failed run left
#                  running, instead of booting a new one
#   MODE           matrix mode (default main)
#   GDB=1          ask the matrix for stack traces on failure (needs gdb in
#                  the guest, which the Guix guest does not have)
#   VIRTIO_SRC     build the drivers from this checkout of hurdkit/virtio,
#                  not from the pinned commit
#   VIRTIO_MATRICES
#                  run the matrices of this directory, not the pinned ones
#   GUIX_DIR       image and run directory (default img/guix-drivers)
#   GUIX_SSH_PORT  forwarded SSH port (default 2231)
#
# A failed matrix leaves the guest running for inspection. After a passing
# matrix the guest must have shut down cleanly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
device="${1:-}"
case "$device" in
    9p)
        matrix=virtio_test.py
        trace_prefix=v9fs_
        ;;
    balloon)
        matrix=virtio_balloon_test.py
        trace_prefix=virtio_balloon_
        ;;
    blk)
        matrix=virtio_blk_test.py
        trace_prefix=virtio_blk_
        ;;
    net)
        matrix=virtio_net_test.py
        trace_prefix=virtio_net_
        ;;
    *)
        echo "usage: guix_virtio_test.sh 9p|balloon|blk|net" >&2
        exit 2
        ;;
esac

GUIX="${GUIX:-guix}"
QEMU_SYSTEM="${QEMU_SYSTEM:-qemu-system-x86_64}"
REUSE="${REUSE:-0}"
MODE="${MODE:-main}"
export GUIX_DIR="${GUIX_DIR:-$REPO_ROOT/img/guix-drivers}"
export GUIX_SSH_PORT="${GUIX_SSH_PORT:-2231}"
export GUIX_OS="$REPO_ROOT/guix/hurd64-drivers.scm"
export GUIX_MEMORY="${GUIX_MEMORY:-2048}"
# The guest boots gnumach-hurdkit-smp; give it as many processors as that
# kernel is built for.
export GUIX_CPUS="${GUIX_CPUS:-2}"
export SSH_KEY_DIR="${SSH_KEY_DIR:-$REPO_ROOT/img/keys}"
export SSH_HOST="${SSH_HOST:-127.0.0.1}"
# What the matrices read (see their docstrings).
export SSH_PORT="$GUIX_SSH_PORT" SSH_KEY="$SSH_KEY_DIR/root_ed25519"
export QEMU_LOG="$GUIX_DIR/$device.trace"
export REUSE GDB="${GDB:-0}" RAM_MB="$GUIX_MEMORY"

guix_vm() {
    GUIX="$GUIX" QEMU_SYSTEM="$QEMU_SYSTEM" bash "$SCRIPT_DIR/guix_vm.sh" "$@"
}

if [[ "$REUSE" == 1 ]]; then
    guix_vm status >/dev/null || {
        echo "guix-virtio-test: REUSE=1, but no guest answers on port $GUIX_SSH_PORT" >&2
        exit 1
    }
else
    guix_vm image
fi

# The binaries the matrix copies into the guest. They link against the
# guest's own libraries, since the same goonix builds both.
build=("$GUIX" build --load-path="$REPO_ROOT/guix/modules" --target=x86_64-pc-gnu)
[[ -z "${VIRTIO_SRC:-}" ]] || build+=(--with-source="hurdkit-virtio=$VIRTIO_SRC")
mapfile -t stores < <("${build[@]}" hurdkit-virtio hurd-9pfs)
(( ${#stores[@]} == 2 )) || {
    echo "guix-virtio-test: building the drivers failed" >&2
    exit 1
}
virtio="${stores[0]}"
export VIRTIO_9P_BIN="$virtio/bin/virtio-9p"
export VIRTIO_BALLOON_BIN="$virtio/bin/virtio-balloon"
export VIRTIO_BLK_BIN="$virtio/bin/virtio-blk"
export VBLK_CLIENT_BIN="$virtio/bin/vblk-client"
export VIRTIO_NET_BIN="$virtio/bin/virtio-net"
export VIRTIO_NET_CLIENT_BIN="$virtio/bin/vnet-client"
export P9FS_BIN="${stores[1]}/bin/9pfs"
# The matrices run on the host, so they are not built for the guest.
if [[ -n "${VIRTIO_MATRICES:-}" ]]; then
    matrices="$(cd "$VIRTIO_MATRICES" && pwd)"
else
    matrices="$("$GUIX" build --load-path="$REPO_ROOT/guix/modules" \
        hurdkit-virtio-matrices)/share/hurdkit-virtio-matrices"
fi
[[ -f "$matrices/$matrix" ]] || {
    echo "guix-virtio-test: there is no $matrix in $matrices" >&2
    exit 1
}

device_args=()
case "$device" in
    9p)
        export SHARE="$GUIX_DIR/share" MOUNT_TAG="${MOUNT_TAG:-hostshare}"
        mkdir -p "$SHARE"
        # The matrix reads this file in the guest.
        printf 'from host\n' > "$SHARE/host-seed.txt"
        device_args=(-fsdev "local,id=virtfs0,path=$SHARE,security_model=none"
                     -device "virtio-9p-pci,fsdev=virtfs0,mount_tag=$MOUNT_TAG,disable-legacy=off,addr=0x5")
        ;;
    balloon)
        # The matrix finds the QEMU monitor next to its log.
        ln -sfn "${XDG_RUNTIME_DIR:-/tmp}/hurdkit-guix-$GUIX_SSH_PORT.monitor" \
            "$GUIX_DIR/virtio-balloon-test-monitor.sock"
        device_args=(-device "virtio-balloon-pci,disable-legacy=off,addr=0x5")
        ;;
    blk)
        export TEST_DISK="$GUIX_DIR/test-disk.img" DISK_MB="${DISK_MB:-64}"
        if [[ "$REUSE" != 1 || ! -f "$TEST_DISK" ]]; then
            python3 "$matrices/virtio_blk_test.py" seed "$TEST_DISK" "$DISK_MB"
        fi
        device_args=(-drive "if=none,id=vd0,file=$TEST_DISK,format=raw,cache=writeback"
                     -device "virtio-blk-pci,drive=vd0,disable-legacy=off,addr=0x5")
        ;;
    net)
        # A second network card with its own user-mode backend; SSH stays
        # on the guest's e1000. guix_vm.sh keeps -netdev for that one, so
        # this card is a -nic, which takes no device properties: the
        # legacy interface that the driver speaks is switched on for the
        # device type.
        device_args=(-global "virtio-net-pci.disable-legacy=off"
                     -nic "user,model=virtio-net-pci")
        ;;
esac

if [[ "$REUSE" != 1 ]]; then
    # Each event is enabled by name: QEMU accepts a pattern here but then
    # writes nothing to the -D log.
    trace_args=()
    while IFS= read -r event; do
        trace_args+=(-trace "enable=$event")
    done < <("$QEMU_SYSTEM" -trace help | grep "^$trace_prefix")
    (( ${#trace_args[@]} > 0 )) || {
        echo "guix-virtio-test: QEMU has no $trace_prefix trace events" >&2
        exit 1
    }
    rm -f "$QEMU_LOG"
    guix_vm start -- "${trace_args[@]}" -D "$QEMU_LOG" "${device_args[@]}"
fi

# The matrix runs in GUIX_DIR and gets the trace log without its directory:
# the balloon matrix connects to the monitor socket next to that log, and
# the path of a Unix socket must stay short however deep GUIX_DIR is.
if ! (cd "$GUIX_DIR" && QEMU_LOG="$device.trace" python3 "$matrices/$matrix" "$MODE"); then
    cat >&2 <<EOF
guix-virtio-test: $device matrix FAILED; the guest is left running.
  QEMU trace: $QEMU_LOG
  serial log: $(cat "$GUIX_DIR/.serial-current" 2>/dev/null)
  SSH:        make guix-ssh GUIX_SSH_PORT=$GUIX_SSH_PORT (or ssh -i $SSH_KEY -p $GUIX_SSH_PORT root@$SSH_HOST)
  rerun:      REUSE=1 GUIX_DIR=$GUIX_DIR GUIX_SSH_PORT=$GUIX_SSH_PORT bash $0 $device
  stop:       GUIX_DIR=$GUIX_DIR GUIX_SSH_PORT=$GUIX_SSH_PORT bash $SCRIPT_DIR/guix_vm.sh stop
EOF
    exit 1
fi

# A REUSE run leaves the guest running. Otherwise the matrix ended with
# poweroff; stop confirms that the Hurd shut down cleanly
# (an unclean shutdown fails the run even though the matrix passed).
if [[ "$REUSE" != 1 ]]; then
    guix_vm stop || {
        echo "guix-virtio-test: the $device matrix passed, but the guest did not shut down cleanly" >&2
        exit 1
    }
fi
echo "guix-virtio-test: $device matrix passed"
