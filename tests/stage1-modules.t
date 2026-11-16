#!/usr/bin/env bash
# Test-first stage 1 module-tree contract. No guest or package build needed.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1
echo '1..7'
failures=0
number=0
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
check 'module tree defines hurdkit-hello-c' grep -q 'define-public hurdkit-hello-c' guix/modules/hurdkit/packages/base.scm
check 'Hurd variants and Rust helpers have their own modules' test -f guix/modules/hurdkit/packages/hurd.scm -a -f guix/modules/hurdkit/packages/rust.scm
check 'Rust hello package is declared' grep -q 'define-public hurdkit-rust-hello' guix/modules/hurdkit/packages/rust.scm
check 'image build loads the module tree' grep -Fq -- '--load-path="$REPO_ROOT/guix/modules"' scripts/guix_vm.sh
check 'driver package builds load the module tree' grep -Fq -- '--load-path="$REPO_ROOT/guix/modules"' scripts/guix_virtio_test.sh
check 'stage 1 package modules evaluate' \
    nix develop ./nix#guix -c env GUILE_AUTO_COMPILE=0 guix build -L guix/modules --target=x86_64-pc-gnu -n hurdkit-shm-unlink hurdkit-tmpfs-io hurdkit-tmpfs-lifetime
check 'vendored shim and Rust packages evaluate' \
    nix develop ./nix#guix -c env GUILE_AUTO_COMPILE=0 guix build -L guix/modules --target=x86_64-pc-gnu -n hurd-epoll-shim hurdkit-rust-hello hurdkit-rust-evloop
exit "$failures"
