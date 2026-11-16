#!/usr/bin/env bash
# TAP regression test: a disposable boot retry must not reuse guest writes.
# QEMU and SSH are synthetic; no real guest, base image, or host service is used.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
# Keep the QEMU monitor and QMP sockets of a guest that may be running
# (they live in XDG_RUNTIME_DIR, named after the SSH port) out of reach.
export XDG_RUNTIME_DIR="$TEST_DIR/run"
mkdir -p "$XDG_RUNTIME_DIR"
export TEST_DIR
cleanup() {
    if [[ -f "$TEST_DIR/synthetic-pids" ]]; then
        while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$TEST_DIR/synthetic-pids"
    fi
    [[ "${DEBUG_GUIX_RETRY:-0}" == 1 ]] && cat "$TEST_DIR/output" 2>/dev/null
    [[ "${DEBUG_GUIX_RETRY:-0}" == 1 ]] || rm -rf "$TEST_DIR"
}
trap cleanup EXIT
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/guix" "$TEST_DIR/keys"
printf 'fake private key\n' > "$TEST_DIR/keys/root_ed25519"
chmod 600 "$TEST_DIR/keys/root_ed25519"
qemu-img create -q -f qcow2 "$TEST_DIR/guix/hurd64.base.qcow2" 16M

for tool in qemu-img sha256sum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "1..0 # SKIP $tool is not installed"
        exit 0
    fi
done
REAL_QEMU_IMG="$(command -v qemu-img)"
export REAL_QEMU_IMG

cat > "$TEST_DIR/bin/qemu-img" <<'SH'
#!/usr/bin/env bash
set -e
"$REAL_QEMU_IMG" "$@"
if [[ "${1:-}" == create ]]; then
    eval 'overlay=${!#}'
    sha256sum "$overlay" | cut -d' ' -f1 >> "$TEST_DIR/created-hashes"
fi
SH
cat > "$TEST_DIR/bin/qemu-system-x86_64" <<'SH'
#!/usr/bin/env bash
set -u
attempt=$(( $(wc -l < "$TEST_DIR/boots" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' -- "$@" > "$TEST_DIR/qemu-$attempt.argv"
disk= pidfile=
while (( $# )); do
    case "$1" in
        -hda) disk="$2"; shift 2 ;;
        -pidfile) pidfile="$2"; shift 2 ;;
        *) shift ;;
    esac
done
actual="$(sha256sum "$disk" | cut -d' ' -f1)"
created="$(tail -n 1 "$TEST_DIR/created-hashes")"
printf 'attempt=%s actual=%s created=%s\n' "$attempt" "$actual" "$created" >> "$TEST_DIR/boots"
# A real timed-out guest may have written anywhere in its overlay. The
# checksum catches that before this synthetic write dirties it further.
printf 'guest-write-from-attempt-%s\n' "$attempt" >> "$disk"
# A separate live process acts as QEMU for the pid liveness check.
setsid sleep 120 < /dev/null > /dev/null 2>&1 &
echo "$!" > "$pidfile"
echo "$!" >> "$TEST_DIR/synthetic-pids"
SH
cat > "$TEST_DIR/bin/ssh" <<'SH'
#!/usr/bin/env bash
exit 255
SH
chmod +x "$TEST_DIR/bin/"*

PATH="$TEST_DIR/bin:$PATH" GUIX_DIR="$TEST_DIR/guix" \
    SSH_KEY_DIR="$TEST_DIR/keys" GUIX_BOOT_TIMEOUT=1 GUIX_BOOT_ATTEMPTS=2 \
    bash "$REPO_ROOT/scripts/guix_vm.sh" start -- \
    -fsdev 'local,id=hostshare,path=/tmp/a path,security_model=none' \
    -device virtio-9p-pci,fsdev=hostshare,mount_tag=hostshare > "$TEST_DIR/output" 2>&1
rc=$?

number=0
ok() { number=$((number + 1)); echo "ok $number - $*"; }
not_ok() { number=$((number + 1)); echo "not ok $number - $*"; }
failures=0
if (( rc != 0 )); then
    ok 'all synthetic boot attempts time out'
else
    not_ok 'synthetic SSH failure unexpectedly succeeded'
    failures=1
fi
if [[ "$(wc -l < "$TEST_DIR/boots")" == 2 ]]; then
    ok 'exactly two boot attempts run'
else
    not_ok 'expected two boot attempts'
    cat "$TEST_DIR/boots"
    failures=1
fi
if awk '{ actual=substr($2, 8); created=substr($3, 9); if (actual != created) exit 1 }' "$TEST_DIR/boots"; then
    ok 'each boot starts from its newly created overlay'
else
    not_ok 'a boot reused writes from the previous attempt'
    sed 's/^/# /' "$TEST_DIR/boots"
    failures=1
fi
if grep -q 'checking the kept state' "$TEST_DIR/output"; then
    not_ok 'disposable retry incorrectly repairs persistent state'
    failures=1
else
    ok 'disposable retry does not run persistent repair'
fi
# A separately sourced command-construction test: arrays cannot be exported
# into another Bash process as an ordinary environment variable.
args_dir="$TEST_DIR/qemu-args"
mkdir "$args_dir"
cat > "$TEST_DIR/bin/record-qemu" <<'SH'
#!/usr/bin/env bash
printf '%s\n' -- "$@"
SH
chmod +x "$TEST_DIR/bin/record-qemu"
PATH="$TEST_DIR/bin:$PATH" GUIX_DIR="$TEST_DIR/guix" QEMU_SYSTEM="$TEST_DIR/bin/record-qemu" \
    bash -c 'repo="$1"; GUIX_SCRIPT_DIR="$repo/scripts" GUIX_REPO_ROOT="$repo" source <(sed "/^command=/,\$d" "$repo/scripts/guix_vm.sh"); GUIX_VM_EXTRA_ARGS=(-fsdev local,id=hostshare,path="/tmp/a path",security_model=none -device virtio-9p-pci,fsdev=hostshare,mount_tag=hostshare); qemu_command test.qcow2 -display none' \
    _ "$REPO_ROOT" > "$args_dir/args"
if [[ "$(sed -n '/^-fsdev$/{n;p;}' "$args_dir/args")" == 'local,id=hostshare,path=/tmp/a path,security_model=none' ]] &&
   [[ "$(sed -n '/^-device$/{n;p;}' "$args_dir/args" | tail -n 1)" == 'virtio-9p-pci,fsdev=hostshare,mount_tag=hostshare' ]]; then
    ok 'complete virtio arguments survive the guest-start boundary'
else
    not_ok 'virtio arguments were split or lost'
    sed 's/^/# /' "$args_dir/args"
    failures=1
fi
if [[ "$(sed -n '/^-hda$/{n;p;}' "$args_dir/args")" == test.qcow2 ]] &&
   [[ "$(sed -n '/^-display$/{n;p;}' "$args_dir/args")" == none ]]; then
    ok 'disk and caller options survive argument forwarding'
else
    not_ok 'disk or caller options were lost'
    sed 's/^/# /' "$args_dir/args"
    failures=1
fi
if [[ "$(sed -n '/^-fsdev$/{n;p;}' "$TEST_DIR/qemu-1.argv")" == 'local,id=hostshare,path=/tmp/a path,security_model=none' ]] &&
   [[ "$(sed -n '/^-device$/{n;p;}' "$TEST_DIR/qemu-1.argv" | tail -n 1)" == 'virtio-9p-pci,fsdev=hostshare,mount_tag=hostshare' ]]; then
    ok 'the start entry point preserves complete virtio arguments'
else
    not_ok 'the start entry point dropped or split virtio arguments'
    sed 's/^/# /' "$TEST_DIR/qemu-1.argv"
    failures=1
fi
# Stop must not silently turn a missing shutdown marker into a clean exit.
stop_dir="$TEST_DIR/stop"
mkdir "$stop_dir"
sleep 90 &
stop_pid=$!
printf '%s\n' "$stop_pid" > "$TEST_DIR/guix/qemu.pid"
set +e
GUIX_DIR="$TEST_DIR/guix" SSH_KEY_DIR="$TEST_DIR/keys" \
    bash -c 'repo="$1"; GUIX_SCRIPT_DIR="$repo/scripts" GUIX_REPO_ROOT="$repo" source <(sed "/^command=/,\$d" "$repo/scripts/guix_vm.sh"); SERIAL_LOG="$2/no-marker.log"; : > "$SERIAL_LOG"; guest_ssh() { return 0; }; cmd_stop' _ "$REPO_ROOT" "$stop_dir" > "$stop_dir/output" 2>&1
stop_rc=$?
set -e
kill "$stop_pid" 2>/dev/null || true
if (( stop_rc != 0 )) && grep -q 'did not shut down' "$stop_dir/output"; then
    ok 'a forced stop without the shutdown marker fails'
else
    not_ok 'missing shutdown marker was reported as success'
    sed 's/^/# /' "$stop_dir/output"
    failures=1
fi
# Persistent mode accepts the same optional QEMU arguments. A fake QEMU
# failure avoids entering the real offline filesystem repair chain.
cat > "$TEST_DIR/bin/qemu-system-x86_64" <<'SH'
#!/usr/bin/env bash
printf '%s\n' -- "$@" > "$TEST_DIR/persist.argv"
exit 1
SH
rm -f "$TEST_DIR/guix/qemu.pid"
set +e
PATH="$TEST_DIR/bin:$PATH" GUIX_DIR="$TEST_DIR/guix" GUIX_SCRIPT_DIR="$REPO_ROOT/scripts" GUIX_REPO_ROOT="$REPO_ROOT" \
    SSH_KEY_DIR="$TEST_DIR/keys" GUIX_BOOT_TIMEOUT=1 GUIX_BOOT_ATTEMPTS=1 \
    bash "$REPO_ROOT/scripts/guix_vm.sh" start persist -- \
    -smp 4 -device virtio-9p-pci,fsdev=hostshare,mount_tag=hostshare \
    > "$TEST_DIR/persist-output" 2>&1
persist_rc=$?
set -e
if (( persist_rc != 0 )) &&
   grep -F -x -A1 -- '-smp' "$TEST_DIR/persist.argv" | tail -n 1 | grep -Fxq 4 &&
   grep -F -x -A1 -- '-device' "$TEST_DIR/persist.argv" | grep -Fxq 'virtio-9p-pci,fsdev=hostshare,mount_tag=hostshare'; then
    ok 'persistent mode forwards QEMU options'
else
    not_ok 'persistent mode dropped its QEMU options'
    sed 's/^/# /' "$TEST_DIR/persist-output"
    failures=1
fi
# A halt command that loses its SSH connection must not block stop forever.
# Fake ssh exits immediately but records its options; a real blocked client
# is terminated by the timeout wrapper.
cat > "$TEST_DIR/bin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' -- "$@" > "$TEST_DIR/halt-ssh.argv"
printf 'Shutdown completed successfully, now in tight loop.\n' > "$TEST_DIR/guix/serial.log"
exit 255
SH
sleep 30 &
printf '%s\n' "$!" > "$TEST_DIR/guix/qemu.pid"
printf '%s\n' "$!" >> "$TEST_DIR/synthetic-pids"
PATH="$TEST_DIR/bin:$PATH" GUIX_DIR="$TEST_DIR/guix" SSH_KEY_DIR="$TEST_DIR/keys" \
    bash "$REPO_ROOT/scripts/guix_vm.sh" stop > "$TEST_DIR/halt-output" 2>&1 || true
if grep -Fq 'timeout --signal=TERM --kill-after=2s 15s' scripts/guix_vm.sh &&
   grep -Fxq halt "$TEST_DIR/halt-ssh.argv"; then
    ok 'the halt SSH command has a finite timeout'
else
    not_ok 'halt SSH command lacks a finite timeout'
    sed 's/^/# /' "$TEST_DIR/halt-output" 2>/dev/null
    sed 's/^/# /' "$TEST_DIR/halt-ssh.argv" 2>/dev/null
    failures=1
fi
# Stop must read the active attempt's log, not the initial snapshot.
cat > "$TEST_DIR/bin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' -- "$@" >> "$TEST_DIR/stop-ssh.argv"
printf 'Shutdown completed successfully, now in tight loop.\n' > "$TEST_DIR/guix/serial-1.log"
exit 255
SH
sleep 30 &
printf '%s\n' "$!" > "$TEST_DIR/guix/qemu.pid"
printf '%s\n' "$!" >> "$TEST_DIR/synthetic-pids"
printf '%s\n' "$TEST_DIR/guix/serial-1.log" > "$TEST_DIR/guix/.serial-current"
: > "$TEST_DIR/guix/serial.log"
: > "$TEST_DIR/guix/serial-1.log"
PATH="$TEST_DIR/bin:$PATH" GUIX_DIR="$TEST_DIR/guix" SSH_KEY_DIR="$TEST_DIR/keys" \
    bash "$REPO_ROOT/scripts/guix_vm.sh" stop > "$TEST_DIR/active-stop-output" 2>&1
active_stop_rc=$?
if (( active_stop_rc == 0 )) && grep -q 'guest has shut down' "$TEST_DIR/active-stop-output" &&
   grep -q 'Shutdown completed successfully' "$TEST_DIR/guix/serial.log"; then
    ok 'stop reads the active serial log and preserves its marker'
else
    not_ok 'stop missed the active serial log'
    sed 's/^/# /' "$TEST_DIR/active-stop-output"
    failures=1
fi
# A stale log pointer must not hide the preserved shutdown marker.
printf '%s\n' "$TEST_DIR/guix/missing.log" > "$TEST_DIR/guix/.serial-current"
printf 'Shutdown completed successfully, now in tight loop.\n' > "$TEST_DIR/guix/serial.log"
sleep 30 &
printf '%s\n' "$!" > "$TEST_DIR/guix/qemu.pid"
printf '%s\n' "$!" >> "$TEST_DIR/synthetic-pids"
PATH="$TEST_DIR/bin:$PATH" GUIX_DIR="$TEST_DIR/guix" SSH_KEY_DIR="$TEST_DIR/keys" \
    bash "$REPO_ROOT/scripts/guix_vm.sh" stop > "$TEST_DIR/stale-pointer-output" 2>&1
stale_pointer_rc=$?
if (( stale_pointer_rc == 0 )) &&
   grep -q 'Shutdown completed successfully' "$TEST_DIR/guix/serial.log"; then
    ok 'a stale serial pointer falls back to the preserved log'
else
    not_ok 'a stale serial pointer hid the preserved log'
    sed 's/^/# /' "$TEST_DIR/stale-pointer-output"
    failures=1
fi
# An image built by another Guix is not the declared system: image must
# refuse it before building anything.
mkdir -p "$TEST_DIR/other-bin"
cat > "$TEST_DIR/other-bin/guix" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_DIR/other-guix.calls"
[[ "${1:-}" == --version ]] && echo 'guix (GNU Guix) 1.5.0'
exit 0
SH
chmod +x "$TEST_DIR/other-bin/guix"
touch "$TEST_DIR/system.scm"
set +e
PATH="$TEST_DIR/bin:$PATH" GUIX="$TEST_DIR/other-bin/guix" \
    GUIX_DIR="$TEST_DIR/image-guix" GUIX_OS="$TEST_DIR/system.scm" \
    bash "$REPO_ROOT/scripts/guix_vm.sh" image > "$TEST_DIR/other-guix-output" 2>&1
other_guix_rc=$?
if (( other_guix_rc != 0 )) && grep -q 'is not goonix' "$TEST_DIR/other-guix-output" &&
   ! grep -q '^system' "$TEST_DIR/other-guix.calls"; then
    ok 'image refuses a Guix other than goonix'
else
    not_ok 'image used a Guix other than goonix'
    sed 's/^/# /' "$TEST_DIR/other-guix-output"
    failures=1
fi
# A halt connection that hangs after the guest has shut down must not
# delay stop: the serial marker ends the wait, not the SSH client.
cat > "$TEST_DIR/bin/ssh" <<'SH'
#!/usr/bin/env bash
printf 'Shutdown completed successfully, now in tight loop.\n' > "$TEST_DIR/guix/serial-1.log"
exec sleep 60
SH
sleep 30 &
printf '%s\n' "$!" > "$TEST_DIR/guix/qemu.pid"
printf '%s\n' "$!" >> "$TEST_DIR/synthetic-pids"
printf '%s\n' "$TEST_DIR/guix/serial-1.log" > "$TEST_DIR/guix/.serial-current"
: > "$TEST_DIR/guix/serial-1.log"
hung_start=$SECONDS
set +e
PATH="$TEST_DIR/bin:$PATH" GUIX_DIR="$TEST_DIR/guix" SSH_KEY_DIR="$TEST_DIR/keys" \
    bash "$REPO_ROOT/scripts/guix_vm.sh" stop > "$TEST_DIR/hung-halt-output" 2>&1
hung_rc=$?
hung_time=$(( SECONDS - hung_start ))
if (( hung_rc == 0 && hung_time < 10 )); then
    ok "a hung halt connection does not delay stop (${hung_time} s)"
else
    not_ok "stop took ${hung_time} s with a hung halt connection (rc $hung_rc)"
    sed 's/^/# /' "$TEST_DIR/hung-halt-output"
    failures=1
fi
# The accounts' SSH keys are created when missing, before Guix reads
# their public halves.
mkdir -p "$TEST_DIR/newkeys-os"
: > "$TEST_DIR/newkeys-os/os.scm"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == --version ]] && echo "guix (GNU Guix) 1.5.0-goonix.test"\nexit 0\n' > "$TEST_DIR/bin/guix"
chmod +x "$TEST_DIR/bin/guix"
set +e
PATH="$TEST_DIR/bin:$PATH" GUIX_DIR="$TEST_DIR/newkeys-guix" \
    GUIX_OS="$TEST_DIR/newkeys-os/os.scm" SSH_KEY_DIR="$TEST_DIR/newkeys" \
    bash "$REPO_ROOT/scripts/guix_vm.sh" image > "$TEST_DIR/newkeys-output" 2>&1
set -e
if [[ -f "$TEST_DIR/newkeys/root_ed25519" && -f "$TEST_DIR/newkeys/peon_ed25519.pub" ]] &&
   [[ "$(ssh-keygen -y -f "$TEST_DIR/newkeys/peon_ed25519" | cut -d' ' -f1,2)" == "$(cut -d' ' -f1,2 "$TEST_DIR/newkeys/peon_ed25519.pub")" ]] &&
   [[ "$(stat -c %a "$TEST_DIR/newkeys/root_ed25519")" == 600 ]]; then
    ok 'image creates missing account SSH keys'
else
    not_ok 'image did not create the account SSH keys'
    sed 's/^/# /' "$TEST_DIR/newkeys-output"
    failures=1
fi
echo "1..$number"
exit "$failures"
