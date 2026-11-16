#!/usr/bin/env bash
# Synthetic boundary test for accelerated Linux screenshots. No VM is booted.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
# Keep the QEMU monitor and QMP sockets of a guest that may be running
# (they live in XDG_RUNTIME_DIR, named after the SSH port) out of reach.
export XDG_RUNTIME_DIR="$TEST_DIR/run"
mkdir -p "$XDG_RUNTIME_DIR"
mkdir "$TEST_DIR/bin" "$TEST_DIR/guest"
cat > "$TEST_DIR/bin/ssh" <<'SH'
#!/usr/bin/env bash
{ printf '%s\n' "$*"; cat; } > "$TEST_DIR/ssh-command"
printf 'fake-key /home/peon/screen.png\n'
SH
cat > "$TEST_DIR/bin/scp" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$TEST_DIR/scp-command"
printf 'png\n' > "${!#}"
SH
cat > "$TEST_DIR/bin/magick" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$TEST_DIR/magick-command"
printf 'P6\n1 1\n255\n\000\000\000' > "${!#}"
SH
chmod +x "$TEST_DIR/bin/"*
printf '%s\n' "$$" > "$TEST_DIR/guest/qemu.pid"
echo '1..6'
PATH="$TEST_DIR/bin:$PATH" TEST_DIR="$TEST_DIR" \
    GUIX_DIR="$TEST_DIR/guest" GUIX_SSH_PORT=2224 \
    SSH_KEY_DIR="$TEST_DIR/keys" GUIX_GUEST_KIND=linux GUIX_GPU=virgl \
    bash "$REPO_ROOT/scripts/guix_vm.sh" screenshot "$TEST_DIR/result.ppm" \
    > "$TEST_DIR/output" 2>&1
rc=$?
# The numbered assertions below use a single global counter for clarity.
number=0
check_numbered() {
    local description="$1"; shift
    number=$((number + 1))
    if "$@"; then echo "ok $number - $description"; else echo "not ok $number - $description"; fi
}
# The output above intentionally preserves the command's own diagnostic log.
check_numbered 'accelerated guest screenshot succeeds' test "$rc" = 0
check_numbered 'guest capture uses niri screenshot IPC' grep -q 'niri msg action screenshot-screen' "$TEST_DIR/ssh-command"
check_numbered 'guest capture discovers the niri IPC socket' grep -q 'NIRI_SOCKET' "$TEST_DIR/ssh-command"
check_numbered 'host transfer uses the peon SSH identity' grep -q 'peon_ed25519' "$TEST_DIR/scp-command"
check_numbered 'host conversion produces PPM' grep -q 'ppm' "$TEST_DIR/magick-command"
check_numbered 'requested output file is returned' grep -q "$TEST_DIR/result.ppm" "$TEST_DIR/output"
[[ "$rc" == 0 ]] || { sed 's/^/# /' "$TEST_DIR/output"; exit 1; }
grep -q 'niri msg action screenshot-screen' "$TEST_DIR/ssh-command" &&
grep -q 'NIRI_SOCKET' "$TEST_DIR/ssh-command" &&
grep -q 'peon_ed25519' "$TEST_DIR/scp-command" &&
grep -q 'ppm' "$TEST_DIR/magick-command" &&
grep -q "$TEST_DIR/result.ppm" "$TEST_DIR/output"
