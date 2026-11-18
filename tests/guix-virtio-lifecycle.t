#!/usr/bin/env bash
# TAP: scripts/guix_virtio_test.sh with fake guix, QEMU, guix_vm.sh and
# matrices. No image is built, nothing is downloaded and no guest is booted.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export TEST_DIR

MATRICES="$TEST_DIR/store/matrices/share/hurdkit-virtio-matrices"
mkdir -p "$TEST_DIR/scripts" "$TEST_DIR/bin" "$TEST_DIR/store/virtio/bin" \
    "$TEST_DIR/store/9pfs/bin" "$MATRICES" "$TEST_DIR/other-matrices"
cp "$REPO_ROOT/scripts/guix_virtio_test.sh" "$TEST_DIR/scripts/"
# guix_vm.sh: log the call; "stop" fails when FAKE_STOP_FAILS=1, "status"
# when FAKE_NO_GUEST=1.
cat > "$TEST_DIR/scripts/guix_vm.sh" <<'SH'
printf '%s\n' "$*" >> "$TEST_DIR/calls"
case "$1" in
    stop) [[ "${FAKE_STOP_FAILS:-0}" != 1 ]] ;;
    status) [[ "${FAKE_NO_GUEST:-0}" != 1 ]] ;;
    *) exit 0 ;;
esac
SH
# The matrices: record where they ran from and their environment; fail
# when FAKE_MATRIX_FAILS=1.
for matrix in virtio_test.py virtio_balloon_test.py virtio_blk_test.py \
    virtio_net_test.py; do
    cat > "$MATRICES/$matrix" <<'PY'
import os, sys
with open(os.path.join(os.environ["TEST_DIR"], "matrix"), "a") as log:
    log.write("directory=%s\n" % os.path.dirname(os.path.abspath(sys.argv[0])))
    log.write(" ".join([os.path.basename(sys.argv[0])] + sys.argv[1:]) + "\n")
    log.write("cwd=%s\n" % os.getcwd())
    for name in ("VIRTIO_9P_BIN", "P9FS_BIN", "VIRTIO_BALLOON_BIN",
                 "VIRTIO_BLK_BIN", "VBLK_CLIENT_BIN", "VIRTIO_NET_BIN",
                 "VIRTIO_NET_CLIENT_BIN", "SSH_PORT", "QEMU_LOG", "SHARE",
                 "TEST_DISK", "REUSE"):
        log.write("%s=%s\n" % (name, os.environ.get(name, "")))
sys.exit(1 if os.environ.get("FAKE_MATRIX_FAILS") == "1" else 0)
PY
done
cp "$MATRICES/virtio_test.py" "$TEST_DIR/other-matrices/"
# guix build: the matrices package, or the two driver packages.
cat > "$TEST_DIR/bin/guix" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_DIR/guix-calls"
case "$*" in
    *hurdkit-virtio-matrices*) printf '%s\n' "$TEST_DIR/store/matrices" ;;
    *) printf '%s\n' "$TEST_DIR/store/virtio" "$TEST_DIR/store/9pfs" ;;
esac
SH
cat > "$TEST_DIR/bin/qemu-system-x86_64" <<'SH'
#!/usr/bin/env bash
printf '%s\n' v9fs_walk v9fs_read virtio_balloon_set_config virtio_blk_req_complete \
    virtio_net_handle_announce
SH
chmod +x "$TEST_DIR/bin/"*

# run DEVICE [VAR=VALUE...]: a fresh run; its exit status is in $rc.
run() {
    local device="$1"; shift
    rm -rf "$TEST_DIR/guest" "$TEST_DIR/calls" "$TEST_DIR/matrix" \
        "$TEST_DIR/guix-calls"
    mkdir -p "$TEST_DIR/guest"
    env PATH="$TEST_DIR/bin:$PATH" GUIX_DIR="$TEST_DIR/guest" \
        XDG_RUNTIME_DIR="$TEST_DIR" "$@" \
        bash "$TEST_DIR/scripts/guix_virtio_test.sh" "$device" \
        > "$TEST_DIR/output" 2>&1
    rc=$?
}

failures=0
number=0
check() {
    local description="$1"; shift
    number=$((number + 1))
    if "$@"; then
        echo "ok $number - $description"
    else
        echo "not ok $number - $description"
        sed 's/^/# /' "$TEST_DIR/output" 2>/dev/null
        failures=$((failures + 1))
    fi
}
called() { grep -q -- "$1" "$TEST_DIR/calls" 2>/dev/null; }
matrix_has() { grep -qx -- "$1" "$TEST_DIR/matrix" 2>/dev/null; }

run bogus
check 'an unknown device is refused' test "$rc" = 2

run 9p
check 'a passing 9p run succeeds' test "$rc" = 0
check 'it builds the image, boots and stops the guest' \
    bash -c 'grep -qx image "$1" && grep -q "^start -- " "$1" && grep -qx stop "$1"' _ "$TEST_DIR/calls"
check 'the guest gets the 9p device and its trace events' \
    bash -c 'grep "^start -- " "$1" | grep -q -- "-trace enable=v9fs_walk .*-D .*virtio-9p-pci,fsdev=virtfs0"' _ "$TEST_DIR/calls"
check 'the matrix is the pinned one, not a script of the working tree' \
    matrix_has "directory=$MATRICES"
check 'the matrix gets the Guix-built driver binaries' \
    bash -c 'grep -qx "VIRTIO_9P_BIN=$1/store/virtio/bin/virtio-9p" "$1/matrix" && grep -qx "P9FS_BIN=$1/store/9pfs/bin/9pfs" "$1/matrix"' _ "$TEST_DIR"

check 'the 9p share is seeded with the file the matrix reads' \
    bash -c '[[ "$(cat "$1/guest/share/host-seed.txt")" == "from host" ]]' _ "$TEST_DIR"

run 9p FAKE_MATRIX_FAILS=1
check 'a failed matrix fails the run' test "$rc" = 1
check 'a failed matrix leaves the guest running' bash -c '! grep -qx stop "$1"' _ "$TEST_DIR/calls"

run 9p FAKE_STOP_FAILS=1
check 'an unclean shutdown after a passing matrix fails the run' \
    bash -c '[[ "$1" == 1 ]] && grep -q "did not shut down cleanly" "$2"' _ "$rc" "$TEST_DIR/output"

run 9p REUSE=1
check 'REUSE=1 runs the matrix on the running guest' \
    bash -c '[[ "$1" == 0 ]] && grep -qx status "$2" && ! grep -q "^start\|^image\|^stop" "$2" && grep -qx REUSE=1 "$3"' _ "$rc" "$TEST_DIR/calls" "$TEST_DIR/matrix"

run 9p REUSE=1 FAKE_NO_GUEST=1
check 'REUSE=1 without a running guest fails before the matrix' \
    bash -c '[[ "$1" == 1 && ! -e "$2" ]]' _ "$rc" "$TEST_DIR/matrix"

run 9p VIRTIO_SRC=/src/virtio
check 'VIRTIO_SRC builds the drivers from that checkout' \
    grep -q -- '--with-source=hurdkit-virtio=/src/virtio' "$TEST_DIR/guix-calls"

run 9p VIRTIO_MATRICES="$TEST_DIR/other-matrices"
check 'VIRTIO_MATRICES runs the matrices of that directory' \
    matrix_has "directory=$TEST_DIR/other-matrices"

run balloon
check 'balloon finds the QEMU monitor next to its log' \
    test "$(readlink "$TEST_DIR/guest/virtio-balloon-test-monitor.sock")" = "$TEST_DIR/hurdkit-guix-2231.monitor"
check 'the matrix reaches that socket by a short path, from the image directory' \
    bash -c 'grep -qx "cwd=$1/guest" "$1/matrix" && grep -qx "QEMU_LOG=balloon.trace" "$1/matrix"' _ "$TEST_DIR"

run blk
check 'blk seeds a test disk and attaches it' \
    bash -c 'grep -qx "virtio_blk_test.py seed $1/guest/test-disk.img 64" "$1/matrix" && grep "^start -- " "$1/calls" | grep -q "file=$1/guest/test-disk.img.*virtio-blk-pci"' _ "$TEST_DIR"
check 'blk runs its matrix with the client binary' \
    matrix_has "VBLK_CLIENT_BIN=$TEST_DIR/store/virtio/bin/vblk-client"

run net
check 'net attaches a second network card with its own backend' \
    bash -c 'grep "^start -- " "$1" | grep -q -- "-trace enable=virtio_net_handle_announce .*-global virtio-net-pci.disable-legacy=off -nic user,model=virtio-net-pci"' _ "$TEST_DIR/calls"
check 'net runs its matrix with the driver and the client binary' \
    bash -c 'grep -qx "VIRTIO_NET_BIN=$1/store/virtio/bin/virtio-net" "$1/matrix" && grep -qx "VIRTIO_NET_CLIENT_BIN=$1/store/virtio/bin/vnet-client" "$1/matrix"' _ "$TEST_DIR"
echo "1..$number"
exit "$failures"
