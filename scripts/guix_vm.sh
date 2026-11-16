#!/usr/bin/env bash
# Build, boot and manage the Guix GNU/Hurd (x86_64-gnu) guest that is
# declared in guix/hurd64.scm.
#
# Usage: guix_vm.sh <command> [arguments]
#
#   image              build the declared system into img/guix/hurd64.base.qcow2
#   start [persist] [-- QEMU-ARG...]
#                      boot in the background and wait for SSH; with
#                      "persist" its disk state is kept between runs
#   status             say whether the guest runs and answers on SSH
#   ssh USER [CMD...]  run a command in the guest (a login shell without CMD)
#   stop               shut the guest down (halt, then stop QEMU)
#   screenshot [FILE]  save the guest output as a PPM picture
#   run                boot in the foreground with a throw-away disk
#   repair             check and repair the root filesystem of the kept state
#   reset-state        delete the kept disk state
#   monitor COMMAND    send a command to the QEMU human monitor
#   qmp COMMAND ...    use QMP: status, screenshot, key, motion, button, quit
#   print-options      print QEMU graphics, tracing and control arguments
#
# The base image is never booted: the guest always runs from a
# copy-on-write overlay, so the base image stays as Guix built it.
#
# Every setting below can be overridden from the environment; the Makefile
# passes its own values.

set -euo pipefail

SCRIPT_DIR="${GUIX_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_ROOT="${GUIX_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
GUIX_SSH_PORT="${GUIX_SSH_PORT:-2223}"
GUIX_DIR="${GUIX_DIR:-$REPO_ROOT/img/guix}"
GUIX_MEMORY="${GUIX_MEMORY:-2048}"
QMP_SOCKET="${QMP_SOCKET:-${XDG_RUNTIME_DIR:-/tmp}/hurdkit-guix-${GUIX_SSH_PORT}.qmp}"
source "$SCRIPT_DIR/guix_qemu_options.sh"

GUIX="${GUIX:-guix}"
GUIX_OS="${GUIX_OS:-$REPO_ROOT/guix/hurd64.scm}"
GUIX_IMAGE_TYPE="${GUIX_IMAGE_TYPE:-hurd64-qcow2}"
# Extra options for "guix system image", for example "--image-size=8G".
GUIX_IMAGE_OPTS="${GUIX_IMAGE_OPTS:-}"
SSH_KEY_DIR="${SSH_KEY_DIR:-$REPO_ROOT/img/keys}"
SSH_HOST="${SSH_HOST:-127.0.0.1}"
# Optional QEMU arguments for "start", supplied after "--". Positional
# parameters preserve spaces in paths and options across script boundaries.
# Bash arrays cannot be exported into a child script.
declare -a GUIX_VM_EXTRA_ARGS=()
QEMU_SYSTEM="${QEMU_SYSTEM:-qemu-system-x86_64}"
QEMU_IMG="${QEMU_IMG:-qemu-img}"
# How long one boot may take until SSH answers, and how often a boot that
# hangs is tried again (see "start" below). Without KVM a boot takes
# minutes; raise the timeout then.
GUIX_BOOT_TIMEOUT="${GUIX_BOOT_TIMEOUT:-180}"
GUIX_BOOT_ATTEMPTS="${GUIX_BOOT_ATTEMPTS:-3}"
GUIX_IMAGE_BASENAME="${GUIX_IMAGE_BASENAME:-hurd64}"
BASE_IMG="$GUIX_DIR/$GUIX_IMAGE_BASENAME.base.qcow2"
# A symlink into /gnu/store. It is a garbage collector root: as long as it
# exists, "guix gc" does not delete the image that Guix built.
STORE_LINK="$GUIX_DIR/$GUIX_IMAGE_BASENAME.store-image"
STATE_IMG="$GUIX_DIR/state.qcow2"
RUN_IMG="$GUIX_DIR/tmp/run.qcow2"
SERIAL_LOG="$GUIX_DIR/serial.log"
PID_FILE="$GUIX_DIR/qemu.pid"
# The monitor socket does not live in GUIX_DIR: the path of a Unix socket
# is limited to 107 bytes, and a checkout in a deep directory exceeds that
# ("UNIX socket path must be less than 108 bytes"). One socket per SSH
# port, so that guests of two checkouts do not collide.
MONITOR_SOCKET="${XDG_RUNTIME_DIR:-/tmp}/hurdkit-guix-${GUIX_SSH_PORT}.monitor"
LOCK_FILE="$GUIX_DIR/.build.lock"
# Image layouts and the halt marker are properties of the declared guest.
ROOT_PARTITION="${GUIX_ROOT_PARTITION:-1}"
GUEST_SSH_PORT="${GUIX_GUEST_SSH_PORT:-2222}"
GUIX_GUEST_KIND="${GUIX_GUEST_KIND:-hurd}"

die() {
    echo "guix_vm: $*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required but not in PATH"
}

# The image has to be built by goonix, the Guix that nix/flake.lock pins:
# another Guix (for example an upstream one installed with "guix pull")
# evaluates a different package graph, and the image is then not the one
# this repository declares. GUIX_ANY_VERSION=1 skips the check.
require_goonix() {
    local version
    version="$("$GUIX" --version 2>/dev/null | head -n 1)"
    [[ "${GUIX_ANY_VERSION:-0}" == 1 || "$version" == *goonix* ]] || \
        die "$GUIX is not goonix ($version); run this inside nix develop ./nix#guix"
}

# The process ID of the running QEMU, or nothing.
qemu_pid() {
    local pid
    [[ -f "$PID_FILE" ]] || return 0
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        echo "$pid"
    fi
}

# guest_ssh [-b] USER [COMMAND...]
#
# Run COMMAND in the guest as USER, or a login shell without COMMAND.
# -b is batch mode: ssh never asks for anything and fails instead.
guest_ssh() {
    local -a batch=()
    if [[ "${1:-}" == "-b" ]]; then
        batch=(-o BatchMode=yes)
        shift
    fi
    local user="$1"; shift
    local key="$SSH_KEY_DIR/${user}_ed25519"
    [[ -f "$key" ]] || die "no SSH key for $user: $key"
    # IdentitiesOnly and IdentityAgent=none: offer this key and nothing
    # else. ssh would otherwise try every key of a running agent first, and
    # sshd closes the connection after six failed attempts.
    ssh -i "$key" -o IdentitiesOnly=yes -o IdentityAgent=none \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10 "${batch[@]}" \
        -p "$GUIX_SSH_PORT" "$user@$SSH_HOST" "$@"
}

# Wait up to TIMEOUT seconds until root can log in. The forwarded port
# accepts connections as soon as QEMU runs, long before sshd listens, so
# only a successful login counts.
wait_for_ssh() {
    local timeout="$1" deadline
    deadline=$(( SECONDS + timeout ))
    while (( SECONDS < deadline )); do
        if guest_ssh -b root true 2>/dev/null; then
            return 0
        fi
        [[ -n "$(qemu_pid)" ]] || die "QEMU exited while the guest was booting; see $SERIAL_LOG"
        sleep 3
    done
    return 1
}

# Stop QEMU without asking the guest. Only for a guest that is hung or
# already halted.
kill_qemu() {
    local pid="$1" i
    kill "$pid" 2>/dev/null || true
    for (( i = 0; i < 10; i++ )); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    if [[ -z "$(qemu_pid)" ]]; then
        rm -f "$MONITOR_SOCKET" "$QMP_SOCKET"
    fi
}

qemu_command() {
    local disk="$1"
    local -a caller_args=("${@:2}")
    local -a accel=() extra=()
    guix_qemu_options || return 1
    if declare -p GUIX_VM_EXTRA_ARGS >/dev/null 2>&1; then
        extra=("${GUIX_VM_EXTRA_ARGS[@]}")
    fi
    local arg
    for arg in "${extra[@]}"; do
        case "$arg" in
            -hda|-pidfile|-monitor|-qmp|-serial|-netdev|-daemonize)
                die "QEMU option $arg is managed by guix_vm.sh; do not override it"
                ;;
        esac
    done
    if [[ -r /dev/kvm && -w /dev/kvm ]]; then
        accel=(-enable-kvm)
    else
        echo "guix_vm: KVM is not available, the guest runs without acceleration" >&2
    fi
    # -M q35: required for the 64-bit Hurd, the default machine type has
    # problems with memory above 4 GB of address space.
    # e1000: the network card the guest has a driver for.
    "$QEMU_SYSTEM" -M q35 "${accel[@]}" -m "$GUIX_MEMORY" \
        -device e1000,netdev=net0 \
        -netdev "user,id=net0,hostfwd=tcp:${SSH_HOST}:${GUIX_SSH_PORT}-:${GUEST_SSH_PORT}" \
        -hda "$disk" "${GUIX_QEMU_OPTIONS[@]}" "${extra[@]}" "${caller_args[@]}"
}

new_overlay() {
    local overlay="$1"
    mkdir -p "$(dirname "$overlay")"
    rm -f "$overlay"
    # The backing file has to be an absolute path: qemu-img resolves a
    # relative one against the directory of the overlay.
    "$QEMU_IMG" create -q -f qcow2 -b "$(readlink -f "$BASE_IMG")" -F qcow2 "$overlay"
}

cmd_image() {
    need "$GUIX"; need "$QEMU_IMG"; need flock
    require_goonix
    [[ -f "$GUIX_OS" ]] || die "system declaration not found: $GUIX_OS"
    [[ -z "$(qemu_pid)" ]] || die "the guest is running; stop it first (make guix-stop)"
    if [[ -e "$STATE_IMG" ]]; then
        die "$STATE_IMG is a kept disk state on top of the current base image and
would be corrupt on top of a new one. Remove it first: make guix-reset-state"
    fi
    mkdir -p "$GUIX_DIR"
    # The build is serialised: two concurrent builds would write the same
    # base image.
    exec 9>"$LOCK_FILE"
    flock 9

    local store_image previous=""
    if [[ -L "$STORE_LINK" ]]; then
        previous="$(readlink -f "$STORE_LINK")"
    fi
    # guix refuses to replace an existing root ("failed to create GC
    # root"), so the old one is removed first. It cannot be renamed into
    # place either: guix registers the root under the path given to
    # --root, and a link moved away from that path no longer protects the
    # image from "guix gc".
    rm -f "$STORE_LINK"
    # guix prints the store file name of the image as the last line of its
    # standard output; the build log goes to standard error.
    # shellcheck disable=SC2086
    store_image="$("$GUIX" system image --load-path="$REPO_ROOT/guix/modules" \
        --image-type="$GUIX_IMAGE_TYPE" \
        $GUIX_IMAGE_OPTS --root="$STORE_LINK" "$GUIX_OS" | tail -n 1)"
    [[ -f "$store_image" ]] || die "guix did not produce an image (got: '$store_image')"
    echo "guix_vm: built $store_image"
    if [[ -f "$BASE_IMG" && "$store_image" == "$previous" ]]; then
        echo "guix_vm: nothing changed, the base image is up to date"
        return 0
    fi

    # The image in the store is read-only and compressed. The base image is
    # an uncompressed copy next to the overlays; it is written to a
    # temporary file first, so that an interrupted build never leaves a
    # partial base image behind.
    "$QEMU_IMG" convert -f qcow2 -O qcow2 "$store_image" "$BASE_IMG.tmp"
    mv -f "$BASE_IMG.tmp" "$BASE_IMG"
    echo "guix_vm: base image $BASE_IMG"
}

cmd_start() {
    local mode="${1:-}" disk
    need "$QEMU_SYSTEM"; need "$QEMU_IMG"
    [[ -f "$BASE_IMG" ]] || die "no base image; build it first (make guix-image)"
    [[ -z "$(qemu_pid)" ]] || die "the guest is already running (pid $(qemu_pid))"
    [[ -n "$QEMU_SYSTEM" ]] || die "QEMU_SYSTEM is empty"
    # Populate this array before expanding it in the launch command below.
    guix_qemu_options || return 1
    case "$mode" in
        "")
            disk="$RUN_IMG"
            ;;
        persist)
            disk="$STATE_IMG"
            [[ -f "$disk" ]] || new_overlay "$disk"
            ;;
        *)
            die "unknown start mode: $mode (use nothing or 'persist')"
            ;;
    esac
    # The 64-bit Hurd sometimes hangs at boot: the TCP/IP server (pfinet)
    # never finishes starting, shepherd waits for it forever with the
    # guest idle, and sshd never starts. A boot that does not answer on SSH
    # in time is stopped and tried again. Disposable retries use a new
    # overlay, since the forcibly stopped one is not a clean boot state.
    local attempt
    # Each attempt has its own serial log; logs of an earlier start would
    # be mistaken for this one's.
    rm -f "$GUIX_DIR"/serial-[0-9]*.log
    for (( attempt = 1; attempt <= GUIX_BOOT_ATTEMPTS; attempt++ )); do
        # A timed-out guest may have written anywhere in its disposable
        # overlay before the forced stop. Never boot that dirty state again:
        # an unclean ext2 filesystem can then fail during early boot.
        # Persistent state is deliberately retained and repaired below.
        if [[ "$mode" != persist ]]; then
            new_overlay "$disk"
        fi
        SERIAL_LOG="$GUIX_DIR/serial-$attempt.log"
        : > "$SERIAL_LOG"
        printf '%s\n' "$SERIAL_LOG" > "$GUIX_DIR/.serial-current"
        rm -f "$MONITOR_SOCKET" "$QMP_SOCKET"
        # The monitor and QMP sockets let the host talk to QEMU itself.
        qemu_command "$disk" "${GUIX_QEMU_DISPLAY_OPTIONS[@]}" -serial "file:$SERIAL_LOG" \
            -monitor "unix:$MONITOR_SOCKET,server=on,wait=off" \
            -pidfile "$PID_FILE" -daemonize
        echo "guix_vm: boot $attempt/$GUIX_BOOT_ATTEMPTS: QEMU started (pid $(qemu_pid)), disk $disk"
        if wait_for_ssh "$GUIX_BOOT_TIMEOUT"; then
            echo "guix_vm: the guest answers on SSH port $GUIX_SSH_PORT"
            return 0
        fi
        echo "guix_vm: no SSH after ${GUIX_BOOT_TIMEOUT}s; last lines of $SERIAL_LOG:" >&2
        tail -n 5 "$SERIAL_LOG" >&2 || true
        kill_qemu "$(qemu_pid)"
        if [[ "$mode" == persist ]]; then
            # The guest was stopped without a shutdown; the root filesystem
            # (ext2, no journal) is checked before the next boot.
            echo "guix_vm: checking the kept state after the forced stop" >&2
            bash "$SCRIPT_DIR/repair_filesystem.sh" "$STATE_IMG" "$ROOT_PARTITION" >/dev/null \
                || die "the repair of $STATE_IMG failed; run make guix-repair to see why"
        fi
    done
    die "the guest did not answer on SSH in $GUIX_BOOT_ATTEMPTS boots; see $SERIAL_LOG"
}

cmd_status() {
    local pid
    pid="$(qemu_pid)"
    if [[ -z "$pid" ]]; then
        echo "stopped"
        return 1
    fi
    if guest_ssh -b root true 2>/dev/null; then
        echo "running (pid $pid), SSH answers on port $GUIX_SSH_PORT"
    else
        echo "running (pid $pid), SSH does not answer"
        return 2
    fi
}

cmd_ssh() {
    [[ $# -ge 1 ]] || die "usage: guix_vm.sh ssh USER [COMMAND...]"
    local user="$1"; shift
    guest_ssh "$user" "$@"
}

cmd_stop() {
    local pid i clean=0
    if [[ "$GUIX_GUEST_KIND" == linux ]]; then
        guest_ssh -b root sync >/dev/null 2>&1 || true
        # Let the guest unmount its filesystems and request ACPI power-off.
        # QMP quit is not a graceful shutdown and must not be used first.
        # Guix's /sbin/halt is Shepherd's halt, not util-linux's halt -p.
        timeout --signal=TERM --kill-after=2s 15s \
            ssh -i "$SSH_KEY_DIR/root_ed25519" -o IdentitiesOnly=yes \
            -o IdentityAgent=none -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            -o ConnectTimeout=10 -o BatchMode=yes \
            -p "$GUIX_SSH_PORT" "root@$SSH_HOST" \
            'sync; herd power-off root' >/dev/null 2>&1 || true
        for (( i = 0; i < 60; i++ )); do
            [[ -z "$(qemu_pid)" ]] && break
            sleep 1
        done
        pid="$(qemu_pid)"
        if [[ -z "$pid" ]]; then
            echo "guix_vm: Linux guest shut down cleanly"
            rm -f "$RUN_IMG"
            return 0
        fi
        echo "guix_vm: Linux guest did not power off; stopping QEMU" >&2
        kill_qemu "$pid"
        return 1
    fi
    pid="$(qemu_pid)"
    if [[ -z "$pid" ]]; then
        echo "guix_vm: the guest is not running"
        rm -f "$PID_FILE" "$RUN_IMG"
        return 0
    fi
    if [[ -s "$GUIX_DIR/.serial-current" ]]; then
        local active_log
        active_log="$(cat "$GUIX_DIR/.serial-current")"
        if [[ -f "$active_log" ]]; then
            SERIAL_LOG="$active_log"
        fi
    fi
    # A clean shutdown matters for a kept state: the root filesystem is
    # ext2 without a journal. "halt" shuts the Hurd down but does not power
    # the virtual machine off; GNU Mach ends in a loop after printing this
    # line on its console (the serial line, see console=com0 in
    # guix/hurd64.scm). From then on QEMU can be stopped safely.
    local done_line="Shutdown completed successfully" halt_pid
    # The SSH client may wait on its connection after halt has already
    # stopped the guest. It is a control channel, not the shutdown gate:
    # it runs in the background, bounded, while the serial log is watched.
    timeout --signal=TERM --kill-after=2s 15s \
        ssh -i "$SSH_KEY_DIR/root_ed25519" -o IdentitiesOnly=yes \
        -o IdentityAgent=none -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=10 -o BatchMode=yes \
        -p "$GUIX_SSH_PORT" "root@$SSH_HOST" halt >/dev/null 2>&1 &
    halt_pid=$!
    for (( i = 0; i < 60; i++ )); do
        kill -0 "$pid" 2>/dev/null || break
        grep -a -q "$done_line" "$SERIAL_LOG" 2>/dev/null && break
        sleep 1
    done
    kill "$halt_pid" 2>/dev/null || true
    wait "$halt_pid" 2>/dev/null || true
    if grep -a -q "$done_line" "$SERIAL_LOG" 2>/dev/null || ! kill -0 "$pid" 2>/dev/null; then
        clean=1
        echo "guix_vm: the guest has shut down"
    else
        echo "guix_vm: the guest did not shut down within 60 s; stopping QEMU anyway" >&2
        echo "guix_vm: run make guix-repair before the next persistent boot" >&2
    fi
    kill_qemu "$pid"
    if [[ "$SERIAL_LOG" != "$GUIX_DIR/serial.log" && -f "$SERIAL_LOG" ]]; then
        cp -f "$SERIAL_LOG" "$GUIX_DIR/serial.log"
    fi
    rm -f "$RUN_IMG"
    echo "guix_vm: stopped"
    (( clean ))
}

cmd_qmp() {
    [[ -n "$(qemu_pid)" ]] || die "the guest is not running"
    [[ -S "$QMP_SOCKET" ]] || die "no QMP socket: $QMP_SOCKET"
    need tclsh
    tclsh "$SCRIPT_DIR/qmp.tcl" "$@"
}

cmd_screenshot() {
    [[ -n "$(qemu_pid)" ]] || die "the guest is not running"
    if [[ "$GUIX_GUEST_KIND" == linux ]]; then
        need scp
        need magick
        bash "$SCRIPT_DIR/linux_screenshot.sh" "${1:-$GUIX_DIR/screen.ppm}"
    elif [[ "${GUIX_GPU:-none}" == none ]]; then
        cmd_qmp screenshot "${1:-$GUIX_DIR/screen.ppm}"
    else
        cmd_qmp screenshot "${1:-$GUIX_DIR/screen.ppm}" gpu0 0
    fi
}

cmd_run() {
    need "$QEMU_SYSTEM"; need "$QEMU_IMG"
    [[ -f "$BASE_IMG" ]] || die "no base image; build it first (make guix-image)"
    [[ -z "$(qemu_pid)" ]] || die "the guest is already running (pid $(qemu_pid))"
    local disk
    mkdir -p "$GUIX_DIR/tmp"
    disk="$(mktemp -u "$GUIX_DIR/tmp/XXXXXX.qcow2")"
    trap 'rm -f "$disk"' EXIT
    new_overlay "$disk"
    echo "guix_vm: booting; the console of the guest follows. SSH: make guix-ssh" >&2
    echo "guix_vm: to stop: 'halt' in the guest, or Ctrl-A X here" >&2
    # -nographic puts the serial line, which carries the console of the
    # guest, on this terminal.
    qemu_command "$disk" -nographic
}

cmd_monitor() {
    (( $# >= 1 )) || die "usage: guix_vm.sh monitor COMMAND"
    [[ -n "$(qemu_pid)" ]] || die "the guest is not running"
    [[ -S "$MONITOR_SOCKET" ]] || die "no monitor socket: $MONITOR_SOCKET"
    # The optional diagnostic monitor shares the upstream harness's Python
    # dependency. Ordinary build/boot/SSH/stop operations do not use it.
    need python3
    python3 -I - "$MONITOR_SOCKET" "$*" <<'PY'
import socket, sys
path, command = sys.argv[1:]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3)
s.connect(path)
try:
    s.recv(65536)
except TimeoutError:
    pass
s.sendall((command + "\n").encode())
while True:
    try:
        data = s.recv(65536)
    except TimeoutError:
        break
    if not data:
        break
    sys.stdout.write(data.decode(errors="replace"))
s.close()
PY
}

cmd_repair() {
    [[ -z "$(qemu_pid)" ]] || die "the guest is running; stop it first (make guix-stop)"
    [[ -f "$STATE_IMG" ]] || die "there is no kept state to repair ($STATE_IMG)"
    bash "$SCRIPT_DIR/repair_filesystem.sh" "$STATE_IMG" "$ROOT_PARTITION"
}

cmd_reset_state() {
    [[ -z "$(qemu_pid)" ]] || die "the guest is running; stop it first (make guix-stop)"
    rm -f "$STATE_IMG"
    echo "guix_vm: kept state removed"
}

cmd_print_options() {
    guix_qemu_options
    printf '%q ' "${GUIX_QEMU_OPTIONS[@]}" "${GUIX_QEMU_DISPLAY_OPTIONS[@]}"
    echo
}

command="${1:-}"
[[ -n "$command" ]] || die "usage: guix_vm.sh image|start [persist] [-- QEMU-ARG...]|status|ssh USER [CMD...]|stop|screenshot [FILE]|run|repair|reset-state|monitor COMMAND|qmp COMMAND|print-options"
shift
case "$command" in
    image)       cmd_image "$@" ;;
    start)
        start_mode=""
        if [[ "${1:-}" == persist ]]; then
            start_mode=persist
            shift
        fi
        if [[ "${1:-}" == -- ]]; then
            shift
            GUIX_VM_EXTRA_ARGS=("$@")
            set --
        fi
        cmd_start "$start_mode" "$@"
        ;;
    status)      cmd_status "$@" ;;
    ssh)         cmd_ssh "$@" ;;
    stop)        cmd_stop "$@" ;;
    screenshot)  cmd_screenshot "$@" ;;
    run)         cmd_run "$@" ;;
    repair)      cmd_repair "$@" ;;
    reset-state) cmd_reset_state "$@" ;;
    monitor)     cmd_monitor "$@" ;;
    qmp)         cmd_qmp "$@" ;;
    print-options) cmd_print_options "$@" ;;
    *)           die "unknown command: $command" ;;
esac
