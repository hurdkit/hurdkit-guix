#!/usr/bin/env bash
# TAP regression test for the Guix virtio wrapper's shutdown and cleanup.
# No real QEMU, Guix image, guest, or host files are used.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export TEST_DIR
mkdir -p "$TEST_DIR/scripts" "$TEST_DIR/share" "$TEST_DIR/store/bin" \
    "$TEST_DIR/img/guix"
touch "$TEST_DIR/img/guix/hurd64.base.qcow2" "$TEST_DIR/key"
printf '#!/usr/bin/env bash\n' > "$TEST_DIR/store/bin/virtio-9p"
printf '#!/usr/bin/env bash\n' > "$TEST_DIR/store/bin/9pfs"
chmod +x "$TEST_DIR/store/bin/"*
cp "$REPO_ROOT/scripts/guix_virtio_test.sh" "$TEST_DIR/scripts/"

cat > "$TEST_DIR/scripts/guix_vm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/guest-commands"
case "$1" in
    start) exit 0 ;;
    stop)
        echo 'guix_vm: the guest did not shut down within 60 s' >&2
        exit 1
        ;;
    *) exit 0 ;;
esac
SH
cat > "$TEST_DIR/matrix" <<'SH'
#!/usr/bin/env bash
printf '24/24 assertions passed\n'
SH
chmod +x "$TEST_DIR/scripts/guix_vm.sh" "$TEST_DIR/matrix"

set +e
TEST_ROOT="$TEST_DIR" GUIX_DIR="$TEST_DIR/guix" SHARE="$TEST_DIR/share" \
    SSH_KEY="$TEST_DIR/key" VIRTIO_STORE="$TEST_DIR/store" \
    P9FS_STORE="$TEST_DIR/store" \
    bash -c 'python3() { "$TEST_ROOT/matrix" "$@"; }; export -f python3; source "$1/scripts/guix_virtio_test.sh"' \
    _ "$TEST_DIR" > "$TEST_DIR/output" 2>&1
rc=$?
set -e
trap - EXIT

echo '1..6'
failures=0
if (( rc != 0 )); then
    echo 'ok 1 - a forced shutdown fails even after a passing matrix'
else
    echo 'not ok 1 - forced shutdown returned success'
    failures=1
fi
if grep -q 'matrix passed, but shutdown failed' "$TEST_DIR/output"; then
    echo 'ok 2 - matrix and lifecycle failure are distinguished'
else
    echo 'not ok 2 - shutdown failure is not reported'
    sed 's/^/# /' "$TEST_DIR/output"
    failures=1
fi
if [[ -d "$TEST_DIR/guix" ]] && ! grep -q 'left running for diagnosis' "$TEST_DIR/output"; then
    echo 'ok 3 - stopped diagnostic state is retained without a live-guest claim'
else
    echo 'not ok 3 - cleanup loses logs or falsely claims the guest is running'
    failures=1
fi
if grep -q '^start -- ' "$TEST_DIR/guest-commands"; then
    echo 'ok 4 - virtio options are forwarded through the start entry point'
else
    echo 'not ok 4 - virtio start options were lost'
    failures=1
fi
if [[ -L "$TEST_DIR/guix/hurd64.base.qcow2" ]] &&
   [[ "$(readlink "$TEST_DIR/guix/hurd64.base.qcow2")" == "$TEST_DIR/img/guix/hurd64.base.qcow2" ]]; then
    echo 'ok 5 - the default diagnostic base is linked before boot'
else
    echo 'not ok 5 - the diagnostic base was not selected explicitly'
    failures=1
fi
rm -rf "$TEST_DIR"
# A relative base override must not become a link relative to GUIX_DIR.
BASE_DIR="$(mktemp -d)"
trap 'rm -rf "$BASE_DIR"' EXIT
printf '#!/usr/bin/env bash\nexit 99\n' > "$BASE_DIR/guix"
chmod +x "$BASE_DIR/guix"
touch "$BASE_DIR/hurd64.base.qcow2" "$BASE_DIR/key"
set +e
(cd "$BASE_DIR" && TEST_ROOT="$BASE_DIR" GUIX="$BASE_DIR/guix" \
    GUIX_DIR="$BASE_DIR/guest" GUIX_BASE_IMG=hurd64.base.qcow2 \
    SHARE="$BASE_DIR/share" SSH_KEY="$BASE_DIR/key" \
    bash "$REPO_ROOT/scripts/guix_virtio_test.sh" > "$BASE_DIR/output" 2>&1)
base_rc=$?
set -e
if [[ "$(readlink "$BASE_DIR/guest/hurd64.base.qcow2")" == "$BASE_DIR/hurd64.base.qcow2" ]]; then
    echo 'ok 6 - relative base overrides are normalized before linking'
else
    echo 'not ok 6 - relative base overrides are normalized before linking'
    sed 's/^/# /' "$BASE_DIR/output"
fi
rm -rf "$BASE_DIR"
exit "$failures"