#!/usr/bin/env bash
# TAP tests for the Tcl QMP client against a synthetic Unix-socket server.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
server_pid=
cleanup() {
    [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
for tool in tclsh socat cc; do command -v "$tool" >/dev/null 2>&1 || { echo "1..0 # SKIP $tool is required"; exit 0; }; done
tclsh <<< 'package require json; package require json::write' >/dev/null 2>&1 || { echo '1..0 # SKIP Tcl json is required'; exit 0; }
cc -O2 -Wall -Wextra -o "$TEST_DIR/fake-qmp" "$REPO_ROOT/tests/fake_qmp.c"
"$TEST_DIR/fake-qmp" "$TEST_DIR/qmp.sock" "$TEST_DIR/requests.jsonl" > "$TEST_DIR/address" 2> "$TEST_DIR/server.log" &
server_pid=$!
for unused in {1..100}; do [[ -s "$TEST_DIR/address" ]] && break; sleep 0.02; done
[[ "$(head -n 1 "$TEST_DIR/address")" == ready ]] || { echo '1..1'; echo 'not ok 1 - fake QMP server did not start'; cat "$TEST_DIR/server.log"; exit 1; }
qmp() {
    QMP_SOCKET="$TEST_DIR/qmp.sock" tclsh "$REPO_ROOT/scripts/qmp.tcl" "$@"
}
failures=0
number=0
check() {
    local description="$1"; shift
    number=$((number + 1))
    if "$@"; then echo "ok $number - $description"; else echo "not ok $number - $description"; failures=$((failures + 1)); fi
}
check_fails() {
    local description="$1"; shift
    "$@" >/dev/null 2>&1
    local rc=$?
    check "$description" test "$rc" != 0
}
qmp status > "$TEST_DIR/status"
check 'status waits for greeting and negotiates capabilities' grep -q 'status=running' "$TEST_DIR/status"
check 'screendump names an absolute output path' qmp screenshot "$TEST_DIR/screen.ppm"
check 'screendump writes the requested absolute filename' grep -Eq "\"filename\" *: *\"$TEST_DIR/screen.ppm\"" "$TEST_DIR/requests.jsonl"
check 'screendump selects the graphical GPU console' qmp screenshot "$TEST_DIR/gpu.ppm" gpu0 0
check 'screendump includes the selected device id' grep -Eq '"device" *: *"gpu0"' "$TEST_DIR/requests.jsonl"
check 'screendump includes the selected head' grep -Eq '"head" *: *0' "$TEST_DIR/requests.jsonl"
check_fails 'screendump rejects a nonnumeric head' qmp screenshot "$TEST_DIR/bad.ppm" gpu0 invalid
check 'key chords are sent as down/up input events' qmp key super+t
check 'key chord is one input command with four events' bash -c "grep -c input-send-event '$TEST_DIR/requests.jsonl' | grep -Fxq 1 && grep -o '\"down\"' '$TEST_DIR/requests.jsonl' | wc -l | grep -Fxq 4"
check 'Super is mapped to the QMP meta_l key' grep -Eq '"data" *: *"meta_l"' "$TEST_DIR/requests.jsonl"
check 'T is lowered to the QMP key name' grep -Eq '"data" *: *"t"' "$TEST_DIR/requests.jsonl"
check 'absolute pointer motion is accepted' qmp motion 120 80
check 'button press and release are accepted' qmp button left down
check 'button release uses the release argument' qmp button left up
check 'trace events can be disabled' qmp trace off 'virtio_gpu_cmd_*'
check 'trace disable sends the event pattern' grep -Eq '"name" *: *"virtio_gpu_cmd_\*"' "$TEST_DIR/requests.jsonl"
check 'trace events can be enabled' qmp trace on 'virtio_gpu_cmd_*'
check 'trace enable uses a JSON boolean' grep -Eq '"enable" *: *true' "$TEST_DIR/requests.jsonl"
check 'quit is sent as a QMP command' qmp quit
check_fails 'server errors fail the command' qmp execute {{"execute":"no-such-command","id":"probe-1"}}
echo "1..$number"
exit "$failures"
