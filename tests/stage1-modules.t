#!/usr/bin/env bash
# Test-first stage 1 module-tree contract. No guest or package build needed.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1
echo '1..11'
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
check 'Guix and toolchain use the same immutable Hurd and Mach pins' \
    bash -c 'hurd_commit=$(sed -n "/define %hurdkit-hurd-commit/{n;s/.*\"\([0-9a-f]\{40\}\)\".*/\1/p;}" guix/modules/hurdkit/packages/hurd.scm); mach_commit=$(sed -n "/define %hurdkit-gnumach-commit/{n;s/.*\"\([0-9a-f]\{40\}\)\".*/\1/p;}" guix/modules/hurdkit/packages/hurd.scm); test "$hurd_commit" = 9b556c6ad91197125bff8261462f51b024ad8e00 && test "$mach_commit" = a6c332067ea3628839f1c5bee5fbf42bb0742008 && grep -Fq "hurd:$hurd_commit" toolchain/pins.mk && grep -Fq "gnumach:$mach_commit" toolchain/pins.mk && grep -Fq "gnumach:https://github.com/hurdkit/gnumach.git" toolchain/pins.mk && grep -Fq "https://github.com/hurdkit/gnumach.git" guix/modules/hurdkit/packages/hurd.scm'
check 'pinned Hurd sources and refreshed compatibility patches are declared' \
    bash -c 'grep -Fq "0ga2pyq2llrmfwqh3s5lq0rl8m0zbs8j0l701f9mrfb3h4xqp7r4" guix/modules/hurdkit/packages/hurd.scm && grep -Fq "hurd-upstream-rumpdisk-compat.patch" guix/modules/hurdkit/packages/hurd.scm && grep -Fq "hurd-upstream-bpf-opcodes.patch" guix/modules/hurdkit/packages/hurd.scm && grep -Fq "rumpdev_ahcisata rumpdev_piixide rumpdev_ata" guix/patches/hurd-upstream-rumpdisk-compat.patch'
check 'tmpfs respects libpager port and write-buffer ownership' \
    bash -c 'grep -Fq "ports_get_send_right (np->dn->u.reg.pager)" guix/patches/tmpfs-mapped-lifetime.patch && grep -Fq "Libpager releases the" guix/patches/tmpfs-mapped-lifetime.patch && ! grep -Fq "return vm_deallocate (mach_task_self (), buf, vm_page_size)" guix/patches/tmpfs-mapped-lifetime.patch'
check 'partial truncation zeros the tail before shrinking its valid extent' \
    bash -c 'grep -Fq "zero_partial_tail (struct node *np, off_t eof)" guix/patches/tmpfs-mapped-lifetime.patch && grep -Fq "err = zero_partial_tail (np, size);" guix/patches/tmpfs-mapped-lifetime.patch && ! grep -Fq "pager_memcpy (np->dn->u.reg.pager" guix/patches/tmpfs-mapped-lifetime.patch && ! grep -Fq "pager_zero_page_tail" guix/patches/tmpfs-mapped-lifetime.patch && ! grep -Fq "tmpfs zero:" guix/patches/tmpfs-mapped-lifetime.patch && ! grep -Fq "tmpfs memcpy:" guix/patches/tmpfs-mapped-lifetime.patch && ! grep -Fq "tmpfs truncate:" guix/patches/tmpfs-mapped-lifetime.patch'
check 'image build loads the module tree' grep -Fq -- '--load-path="$REPO_ROOT/guix/modules"' scripts/guix_vm.sh
check 'driver package builds load the module tree' grep -Fq -- '--load-path="$REPO_ROOT/guix/modules"' scripts/guix_virtio_test.sh
check 'stage 1 package modules evaluate' \
    nix develop ./nix#guix -c env GUILE_AUTO_COMPILE=0 guix build -L guix/modules --target=x86_64-pc-gnu -n hurdkit-shm-unlink hurdkit-tmpfs-io hurdkit-tmpfs-lifetime
check 'vendored shim and Rust packages evaluate' \
    nix develop ./nix#guix -c env GUILE_AUTO_COMPILE=0 guix build -L guix/modules --target=x86_64-pc-gnu -n hurd-epoll-shim hurdkit-rust-hello hurdkit-rust-evloop
exit "$failures"
