#!/usr/bin/env bash
# TAP: the image source is a declaration by default, or a flake reference.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/hurdkit-guix-image.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/guix" "$work/keys" "$work/out"
printf 'ssh-ed25519 test\n' > "$work/keys/root_ed25519.pub"
printf 'ssh-ed25519 test\n' > "$work/keys/peon_ed25519.pub"
printf 'public host signing key\n' > "$work/host-signing-key.pub"
printf 'synthetic identity\n' > "$work/keys/root_ed25519"
printf 'synthetic identity\n' > "$work/keys/peon_ed25519"
: > "$work/declaration.scm"
printf 'synthetic image\n' > "$work/store-image"

cat > "$work/bin/guix" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
    echo 'guix (GNU Guix) goonix'
    exit 0
fi
printf '%s\n' "$@" > "$GUIX_TEST_CALLS"
printf '%s\n' "$GUIX_TEST_IMAGE"
SH
cat > "$work/bin/qemu-img" <<'SH'
#!/usr/bin/env bash
[[ "$1" == convert && "$2" == -f && "$3" == qcow2 &&
   "$4" == -O && "$5" == qcow2 ]] || exit 1
cp "$6" "$7"
SH
cat > "$work/bin/flock" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$work/bin/"*
export GUIX_TEST_CALLS="$work/calls" GUIX_TEST_IMAGE="$work/store-image"
export GUIX="$work/bin/guix" QEMU_IMG="$work/bin/qemu-img"
export GUIX_DIR="$work/guix" SSH_KEY_DIR="$work/keys"
export GUIX_HOST_SIGNING_KEY="$work/host-signing-key.pub"
export PATH="$work/bin:$PATH"

number=0
failures=0
check() {
    local description="$1"; shift
    number=$((number + 1))
    if "$@"; then
        echo "ok $number - $description"
    else
        echo "not ok $number - $description"
        failures=$((failures + 1))
    fi
}

if ! GUIX_OS="$work/declaration.scm" bash "$REPO_ROOT/scripts/guix_vm.sh" image \
    > "$work/file-output" 2>&1; then
    cat "$work/file-output"
    exit 1
fi
check 'a file declaration stays the default image source' \
    bash -c 'test "$(tail -n 1 "$1")" = "$2" &&
        grep -qx -- "--load-path=$3/guix/modules" "$1" &&
        grep -qx -- "--image-type=hurd64-qcow2" "$1" &&
        ! grep -q -- '^--option=' "$1"' \
    _ "$work/calls" "$work/declaration.scm" "$REPO_ROOT"

rm -f "$work/guix/hurd64.base.qcow2"
if ! GUIX_OS='.#hurd64' bash "$REPO_ROOT/scripts/guix_vm.sh" image \
    > "$work/flake-output" 2>&1; then
    cat "$work/flake-output"
    exit 1
fi
check 'a flake reference is passed to guix without a file check' \
    bash -c 'test "$(tail -n 1 "$1")" = "$3#hurd64" &&
        ! grep -q -- "--load-path=" "$1" &&
        grep -qx -- "--image-type=hurd64-qcow2" "$1" &&
        grep -Fxq -- "--option=root-public-key=$(cat "$2/keys/root_ed25519.pub")" "$1" &&
        grep -Fxq -- "--option=peon-public-key=$(cat "$2/keys/peon_ed25519.pub")" "$1" &&
        grep -Fxq -- "--option=host-signing-key=$(cat "$2/host-signing-key.pub")" "$1"' \
    _ "$work/calls" "$work" "$REPO_ROOT"
check 'make preserves a flake reference as the image source' \
    bash -c 'test "$(make -s -f "$1/Makefile" --no-print-directory \
        GUIX_OS=.#hurd64 GUIX_DIR="$2" SSH_KEY_DIR="$2/keys" \
        GUIX="$2/bin/guix" QEMU_IMG="$2/bin/qemu-img" guix-image)" != "" &&
        test "$(tail -n 1 "$2/calls")" = "$1#hurd64" &&
        test -f "$2/guix/hurd64.base.qcow2"' \
    _ "$REPO_ROOT" "$work"
# A relative flake reference is anchored to the repository, not the cwd.
rm -f "$work/calls" "$work/guix/hurd64.base.qcow2"
if ! (cd / && GUIX_OS='.#hurd64' bash "$REPO_ROOT/scripts/guix_vm.sh" image \
    > "$work/cwd-output" 2>&1); then
    cat "$work/cwd-output"; exit 1
fi
check 'a relative flake reference resolves to the repository from any cwd' \
    bash -c 'test "$(tail -n 1 "$1")" = "$2#hurd64"' _ "$work/calls" "$REPO_ROOT"

# A goonix without the flake command must refuse a flake reference, not run
# "guix system image .#..." that the pinned shell guix cannot understand.
cat > "$work/bin/guix-noflake" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then echo 'guix (GNU Guix) goonix'; exit 0; fi
if [[ "${1:-}" == flake ]]; then echo 'guix: flake: command not found' >&2; exit 1; fi
printf '%s\n' "$@" > "$GUIX_TEST_CALLS"
printf '%s\n' "$GUIX_TEST_IMAGE"
SH
chmod +x "$work/bin/guix-noflake"
rm -f "$work/calls" "$work/guix/hurd64.base.qcow2"
set +e
GUIX="$work/bin/guix-noflake" GUIX_OS='.#hurd64' \
    bash "$REPO_ROOT/scripts/guix_vm.sh" image > "$work/noflake-output" 2>&1
noflake_rc=$?
set -e
check 'a flake reference is refused when guix has no flake command' \
    bash -c 'test "$1" -ne 0 && grep -q "no flake command" "$2" &&
        test ! -e "$3"' _ "$noflake_rc" "$work/noflake-output" "$work/calls"

echo "1..$number"
exit "$failures"
