#!/usr/bin/env bash
# Linux shutdown regression: request guest power-off, never QMP quit first.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
# Keep the QEMU monitor and QMP sockets of a guest that may be running
# (they live in XDG_RUNTIME_DIR, named after the SSH port) out of reach.
export XDG_RUNTIME_DIR="$TEST_DIR/run"
mkdir -p "$XDG_RUNTIME_DIR"
mkdir "$TEST_DIR/bin" "$TEST_DIR/keys"
printf 'synthetic key\n' > "$TEST_DIR/keys/root_ed25519"
cat > "$TEST_DIR/bin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' -- "$@" >> "$TEST_DIR/ssh-calls"
if [[ "$*" == *'power-off'* ]]; then
    rm -f "$TEST_DIR/guest/pid"
fi
exit 255
SH
cat > "$TEST_DIR/bin/timeout" <<'SH'
#!/usr/bin/env bash
while [[ "${1:-}" == --* ]]; do shift; done
shift # the timeout duration, irrelevant to this synthetic command
"$@"
SH
chmod +x "$TEST_DIR/bin/"*
mkdir "$TEST_DIR/guest"
printf '1\n' > "$TEST_DIR/guest/pid"
PATH="$TEST_DIR/bin:$PATH" GUIX_DIR="$TEST_DIR/guest" \
    SSH_KEY_DIR="$TEST_DIR/keys" GUIX_GUEST_KIND=linux TEST_DIR="$TEST_DIR" \
    bash "$REPO_ROOT/scripts/guix_vm.sh" stop > "$TEST_DIR/output" 2>&1
rc=$?
echo '1..1'
if (( rc == 0 )) && grep -q 'guest shut down cleanly' "$TEST_DIR/output" &&
   grep -q 'sync; herd power-off root' "$TEST_DIR/ssh-calls" &&
   ! grep -q 'halt -p' "$TEST_DIR/ssh-calls"; then
    echo 'ok 1 - Linux stop requests a guest power-off before considering QEMU'
else
    echo 'not ok 1 - Linux stop requests a guest power-off before considering QEMU'
    sed 's/^/# /' "$TEST_DIR/output" "$TEST_DIR/ssh-calls" 2>/dev/null
    exit 1
fi
