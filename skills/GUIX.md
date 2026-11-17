# Skill: Build and Manage the Guix 64-bit GNU/Hurd Guest

## Trigger

Use this skill for work on the Guix guest (`guix/`, `guix.mk`,
`scripts/guix_*.sh`), or when a Guix guest does not boot or answer.

## Inputs

- `nix/flake.nix` and `nix/flake.lock`: the `guix` development shell, with
  goonix (our fork of GNU Guix) at a pinned commit.
- `guix/hurd64.scm`: the system declaration of the guest.
- `guix/goonix.scm`: goonix as the guest's own Guix (same commit as the lock).
- `guix.mk`: the make targets of the guest.
- `scripts/guix_vm.sh`: builds, boots and manages the guest.
- `img/guix/`: the base image, overlays and logs of the guest.
- `img/keys/`: the SSH keys of the guest's root and peon accounts.

## Goal

Build and boot a 64-bit GNU/Hurd guest from a declarative Guix system,
with key-based SSH.

## Constraints

- The Guix guest and the Debian pipeline do not depend on each other.
  Nothing of the guest reads a variable of the Makefile or runs a script of
  the Debian pipeline (`tests/guix-standalone.t` checks that), and the
  Debian pipeline uses nothing of the guest: the Makefile only includes
  `guix.mk`. The two share `img/keys/`.
- Whatever the guest needs from another repository, or from this one's
  other half, is a Guix package or origin at a pinned commit with its hash.
  A pin moves only when someone moves it, so a change elsewhere cannot
  break a Guix target.
- This document states no counts, durations, versions or test results. A
  pin or a default that moves must not make it wrong: name the variable or
  the command that tells instead.
- Never edit goonix for this work, and never change the guest's glibc:
  every package links against it, so a changed glibc rebuilds the whole
  guest locally.

## Procedure

### Build the image

Host, shell and guest all run goonix at the commit that `nix/flake.lock`
pins: the host's daemon (see "Host daemon"), the `guix` command of the
`nix develop ./nix#guix` shell, and the guest's Guix through
`guix/goonix.scm`. Run every Guix command in that shell and never run
`guix pull` for this work.

```sh
nix develop ./nix#guix
guix system image --image-type=hurd64-qcow2 guix/hurd64.scm
```

The declaration reads the accounts' public keys from `img/keys/`
(`root_ed25519.pub`, `peon_ed25519.pub`); `ssh-keygen -q -t ed25519 -N ''
-f img/keys/root_ed25519` creates a missing pair.

`guix system image` prints the image in the store: a read-only, compressed
qcow2. The first build on a machine cross-compiles goonix for the guest;
everything else is downloaded from the build farm. Boot it without changing
it:

```sh
qemu-system-x86_64 -M q35 -enable-kvm -m 2048 -snapshot -hda IMAGE \
    -device e1000,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2223-:2222 -nographic
ssh -i img/keys/root_ed25519 -p 2223 root@127.0.0.1 guix --version
```

The guest's `guix --version` prints the same goonix line as on the host.

### Host daemon

The host's Guix daemon has to be goonix too. On NixOS, with goonix as an
input of the system flake (`goonix.url = "github:hurdkit/goonix/goonix";`,
locked at the commit `nix/flake.lock` pins; goonix's `main` branch mirrors
upstream Guix, its `goonix` branch has the fork):

```nix
services.guix.enable = true;
services.guix.package = inputs.goonix.packages.${pkgs.stdenv.hostPlatform.system}.default;
services.avahi.enable = false;  # services.guix would switch it on
```

After a switch that changes the daemon, check `systemctl is-active
guix-daemon.socket`. If the service restarted before its socket ("Socket
service guix-daemon.service already active, refusing"), run `systemctl stop
guix-daemon.service` and `systemctl start guix-daemon.socket`.

To move the goonix pin, update `nix/flake.lock` (`nix flake update goonix
--flake ./nix`), the system flake's lock, and `%goonix-commit` with its
hash in `guix/goonix.scm`; `tests/goonix-pin.t` compares the last two.

### Host archive signing

`guix/hurd64.scm` authorizes the host's archive signing key,
`/etc/guix/signing-key.pub`, when the host has one, so `guix copy` from the
host into the guest works. `make guix-authorize-host` creates a missing key
pair (the private key stays in `/etc/guix/signing-key.sec`); on NixOS
without `/run/wrappers/bin` in `PATH`, add
`GUIX_SUDO=/run/wrappers/bin/sudo`. An image built before the key existed
does not trust it: rebuild the image.

### Boot and manage the guest

```sh
make guix-image guix-start    # build, then boot and wait for SSH
make guix-ssh                 # a root shell; guix-ssh-peon for peon
make guix-stop
```

`make guix-image` builds the image as above, converts it into
`img/guix/hurd64.base.qcow2` and creates the accounts' SSH keys in
`img/keys/` when they are missing; a second run reports that it is up to
date. It refuses a `guix` whose first `--version` line lacks `goonix`
(`GUIX_ANY_VERSION=1` overrides that for experiments).

`make guix-start` boots a disposable overlay of the base image, waits for a
successful SSH login on the host port `GUIX_SSH_PORT`, and boots again when
a boot does not answer in time (G15). `make guix-status` says whether the
guest runs and answers. `make guix-stop` sends `halt` over SSH, waits for
GNU Mach's shutdown marker in the serial log, then stops QEMU, because a
Hurd halt does not power the machine off (G16). A forced stop without that
marker returns failure. The variables at the top of `guix.mk` and of
`scripts/guix_vm.sh` say what can be set, with their defaults.

### Rebuild and persistent state

Change the declaration, then `make guix-stop guix-image guix-start`.

`make guix-start-persist` keeps the disk in `img/guix/state.qcow2`, an
overlay of the current base image (G8). After an unclean stop, run
`make guix-repair`: it checks the root filesystem of the kept state with
`e2fsck`, and what the guest had not written yet is lost (`sync` does not
wait on the Hurd). `make guix-reset-state` deletes the kept state; `make
guix-image` refuses to replace the base while one exists.

### When a guest does not answer

Read `img/guix/serial-N.log` (`.serial-current` names the active boot;
`serial.log` keeps the last one after stop) and save the screen with
`make guix-screenshot` (`img/guix/screen.ppm`). `bash scripts/guix_vm.sh
monitor 'info pci'` talks to the QEMU monitor. A boot that times out gets a
fresh overlay; a kept state is repaired before the next attempt.

### Package modules, GNU Mach and Hurd variants

Packages of this repository are Guile modules under `guix/modules/hurdkit/`;
`guix_vm.sh` and the test scripts pass `-L guix/modules`. Build one with
`guix build -L guix/modules --target=x86_64-pc-gnu NAME`. A module that
does not compile breaks every image build: `make guix-test` (its
`guix-packages.t`) shows which.

`(hurdkit packages hurd)` has `gnumach-hurdkit` (Hurdkit's GNU Mach, with
its shared-interrupt fixes) and `hurd-hurdkit`, a newer Hurd, each at a
commit that the module pins. `hurd-hurdkit` carries two compatibility
patches for goonix's older rumpkernel and GNU Mach headers, and builds
serially (G23).

`operating-system-with-hurd` from `(hurdkit system)` replaces the Hurd of a
system: the boot servers, and also `pfinet`, the console, getty and login,
whose services otherwise keep starting goonix's default Hurd. In such a
guest, `ps -ef` shows every translator from the one Hurd.
`guix/hurd64-hurdkit.scm` is the guest with both.

### niri platform guest

`make stage1-check` builds `guix/hurd64-platform.scm` into
`img/guix-platform/`, boots it on its own port and runs the platform's test
programs in it; `scripts/stage1_check.sh` lists them. The guest has:

- `hurd-tmpfs-mapped`, which is `hurd-hurdkit` with
  `guix/patches/hurd-tmpfs-keep-mapped.patch`: when the last reference to
  an unlinked file goes away, tmpfs no longer shrinks its memory object to
  zero, so the file's mappings keep working. `tmpfs-shm DIRECTORY`
  (`tests/hurd/tmpfs-shm.c`) checks it on `/dev/shm`, and on ext2 as the
  control; it also runs on Linux.
- `hurd-shm`, which adds the fix that shared memory on a tmpfs needs from
  the default pager; GNU Mach's part is in `gnumach-hurdkit` (G22).
- `hurd-epoll-shim`, the epoll, eventfd, timerfd and signalfd library for
  the libwayland port, with its TAP suites (`hurd-epoll-shim-test-NAME`).
  It lives in its own repository, github.com/hurdkit/hurd-epoll-shim, and
  `(hurdkit packages base)` pins the commit.
- `hurdkit-rust-hello` and the `hurdkit-rust-evloop` TAP test (calloop and
  polling on the Hurd), built by goonix's cargo build system once the Rust
  standard library builds for the Hurd (`(hurdkit packages rust)`).

### Driver tests

```sh
make guix-virtio-test          # virtio-9p and 9pfs
make guix-virtio-balloon-test
make guix-virtio-blk-test
```

Each target runs one test matrix of Hurdkit's virtio drivers against a
separate, disposable guest (`guix/hurd64-drivers.scm`, `img/guix-drivers/`).
Drivers and matrices are Guix packages of `(hurdkit packages virtio)` at
pinned commits: `scripts/guix_virtio_test.sh` runs that snapshot of the
matrices and never the scripts of the working tree, so work on those cannot
break these targets. To test newer drivers or matrices, move the pins in
the module and adapt `guix_virtio_test.sh` to what the new matrices expect;
`VIRTIO_SRC=DIR` and `VIRTIO_MATRICES=DIR` try a local checkout first.

After a passing matrix the guest has to shut down cleanly. A failed matrix
leaves the guest running and prints how to reach it; `REUSE=1` runs the
matrix again on that guest.

### Graphics harness

`GUIX_GPU` (`none`, `2d`, `virgl`, `venus`, `nctx`) adds a virtio-gpu
device, `GUIX_DISPLAY` (`none`, `egl-headless`, `gtk`) the display, and
`GUIX_HOST_GPU` (`amd`, `nvidia`) the host GPU that renders, found by its
driver in sysfs. For Venus, the host's Vulkan ICD of that GPU is selected
through `VK_DRIVER_FILES`; `GUIX_VK_DEVICE` and `GUIX_VK_ICD_FILE` override
it. `GUIX_TRACE='virtio_gpu_cmd_*'` records QEMU trace events into
`GUIX_TRACE_FILE`, `GUIX_CPUS` sets the number of CPUs, and
`GUIX_QEMU_ARGS` adds QEMU options. The defaults leave the guest as it was.

Every guest has a QMP socket next to its monitor socket. `make guix-qmp
GUIX_QMP_ARGS=...` runs `scripts/qmp.tcl`: `status`, `screenshot FILE
[DEVICE HEAD]`, `key super+t`, `motion X Y`, `button left down`, `trace
on|off PATTERN`, `execute JSON`. `scripts/ppm_check.tcl` checks screenshots:
`dimensions`, `region` (mostly one colour), `differs` (at most N percent of
the pixels differ) and `changed` (at least N percent do).

### Linux niri reference

`guix/linux-reference.scm` is an x86_64 Linux Guix system with niri, foot,
Mesa's tools, glmark2 and the Vulkan tools, logged in as `peon` on tty1
straight into niri. It shows what the Hurd guest should eventually do:

```sh
make linux-ref-image
make linux-ref-start GUIX_GPU=virgl GUIX_DISPLAY=egl-headless GUIX_HOST_GPU=nvidia
make linux-ref-screenshot
make linux-ref-qmp GUIX_QMP_ARGS='key super+t'
make linux-ref-stop
```

It has its own port and `img/guix-linux/`. `linux-ref-screenshot` takes the
picture through niri's IPC, because QMP `screendump` cannot read an
accelerated scanout. `make stage0-check` is the live gate: the Hurd guest
boots and stops cleanly, and for each GPU in `STAGE0_GPUS` and path (virgl,
and Venus for `STAGE0_VENUS_GPUS`) the reference reports that GPU as
renderer, runs glmark2, takes screenshots, opens foot by QMP keys and stops
cleanly. Artifacts go to `img/stage0/`.

## Pitfalls

**G1. An image built by another Guix is a different system.** Another
`guix` can come first in `PATH`, for example one installed by `guix pull`
into `~/.config/guix/current`. Its package graph differs, so the image
differs from the declared one even with identical files. Check that the
first line of `guix --version` contains `goonix`.

**G2. Substitutes exist only for commits the build farm built.** GNU Mach,
the Hurd, glibc and the cross toolchain of the guest are downloaded
pre-built because goonix has the package definitions of an upstream Guix
commit that the farm built. A goonix commit that changes those definitions
makes Guix build a toolchain and a C library locally, which takes hours.
Check before a long wait: `guix system image --dry-run
--image-type=hurd64-qcow2 guix/hurd64.scm` lists configuration files,
`goonix-…` and nothing named `gcc-…`, `glibc-…`, `hurd-…` or `gnumach-…`.

**G3. Our image itself cannot be downloaded.** Its derivation differs from
the build farm's, so its store path does too. The packages inside are the
same and are downloaded.

**G4. The image build needs `/tmp` on ext4.** Guix records each Hurd
translator as a `gnu.translator` extended attribute in the daemon's build
directory under `/tmp`; Linux accepts `gnu.*` attributes on ext4 only. On
tmpfs or btrfs the build prints `Operation not supported` and `Ignoring...Good
Luck!`, "succeeds", and the guest does not come up. Check `findmnt -no
FSTYPE -T /tmp`.

**G5. sshd in the guest listens on 2222, not 22.** The port forward ends in
`-:2222`. With `-:22` QEMU accepts the connection and the guest resets it,
exactly like a guest that is still booting.

**G6. The 64-bit guest needs `-M q35`.** The default machine type gives the
64-bit Hurd memory problems.

**G8. A kept state is tied to one base image.** `img/guix/state.qcow2`
stores only the blocks that differ from the base. On a new base it
describes a disk that no longer exists and the guest sees a corrupt
filesystem. Copy what you need out with `scp`, then `make guix-reset-state`.

**G9. Nix only sees files that git knows.** After editing `nix/flake.nix`,
`git add` it before `nix develop`. (Guix reads `guix/` from the working
directory, so this does not apply there.)

**G10. The store image is read-only and compressed.** `guix_vm.sh image`
keeps it from the garbage collector with `--root=` (the link
`img/guix/hurd64.store-image`) and converts it into the base image. Never
boot the store file without `-snapshot`.

**G11. The guest has little free disk space.** The image is sized to its
content. Set `GUIX_IMAGE_OPTS=--image-size=8G` when you need room.

**G13. Parallel heavy jobs make everything look hung.** Building goonix or
an image while a guest runs saturates the disk, and `nix develop` waits
silently on a store lock. Run heavy steps one after another; `cat
/proc/pressure/io` shows whether the disk is the bottleneck.

**G14. An open port is not a ready guest.** QEMU accepts the forwarded port
at once. Only a successful login proves the guest is up.

**G15. The guest sometimes hangs at boot, in the network setup.** Such a
boot sits idle after `Service file-systems has been started.`; sshd never
starts and SSH fails with `Connection timed out during banner exchange`. A
good boot prints `irq handler [11]: new delivery port … for
/hurd/netdde(…)` right after that line (netdde, the network card driver,
starting when `pfinet` opens `eth0`); a hung boot never does. The cause is
not known. `guix_vm.sh start` stops a boot without SSH after
`GUIX_BOOT_TIMEOUT` seconds and tries again, `GUIX_BOOT_ATTEMPTS` times in
all.

**G16. `halt` does not power the virtual machine off.** GNU Mach prints
`Shutdown completed successfully, now in tight loop.` on its console, which
the declaration puts on the serial line (`console=com0`), and QEMU keeps
running. `guix_vm.sh stop` waits for that line, then stops QEMU.

**G17. Ignore "Consider running 'guix pull'".** goonix has no channel
information, so `guix` prints it every time. See G1.

**G18. `guix system image --root=LINK` does not replace a link.** It fails
with `failed to create GC root`, so `guix_vm.sh image` removes the old link
first. A link renamed after the build no longer protects the image.

**G19. A Unix socket path has at most 107 bytes.** The sockets that talk
to QEMU therefore live in `$XDG_RUNTIME_DIR`, named after the SSH port.

**G20. After 9pfs has been used, `halt` may not finish.** In guests in
which a 9pfs translator ran, sshd stops on `halt` but GNU Mach's shutdown
marker often never comes, also after `settrans -g`. The cause is not known.
`guix_vm.sh stop` then stops QEMU and exits nonzero, so `make
guix-virtio-test` fails at that point even when its matrix passed; with a
kept state, run `make guix-repair` before the next persistent boot.

**G22. The guest has no swap.** Pages that GNU Mach evicts under memory
pressure go to the default pager, which has nowhere to write them: the
serial log shows `(default pager): data_return write error, losing data`,
and every later page-in of that memory object fails (SIGBUS). The same two
lines after a tmpfs file is deleted are harmless: the kernel returns the
dirty pages of an object that is going away. `hurd-shm` and
`gnumach-hurdkit` fix the two cases that lost shared memory without any
memory pressure: a tmpfs file truncated in the middle of a resident page
stopped GNU Mach in its debugger (`vm_map_copyin_page_list: Assertion
'm->wire_count == 1'`), and `msync` moved the pages of tmpfs files and
anonymous shared memory to the default pager. The kernel's fixes are in
its `hurdkit` branch; the default pager's is posted to
github.com/hurdkit/hurd and is `guix/patches/hurd-defpager-truncate-copy.patch`
until the pinned commit has it.

**G23. The newer Hurd's `make -j` is racy.** `utils/` fails with `No rule to
make target 'auth_requestUser.stamp'`, often enough that `hurd-hurdkit`
builds serially.

## Verification

Run these in `nix develop ./nix#guix`. Each command exits with zero status
when its checks pass and prints what failed otherwise.

| Check | Command |
|---|---|
| Scripts and declarations (boots nothing) | `make guix-test` |
| The guest boots, answers and halts | `make guix-image guix-start guix-ssh-peon guix-stop` |
| The guest with Hurdkit's GNU Mach and Hurd | `GUIX_DIR=$PWD/img/guix-hurdkit GUIX_SSH_PORT=2225 GUIX_OS=$PWD/guix/hurd64-hurdkit.scm bash scripts/guix_vm.sh image`, then `start`, `ssh root ps -ef` and `stop` the same way |
| The platform guest's tests | `make stage1-check` |
| The driver matrices | `make guix-virtio-test guix-virtio-balloon-test guix-virtio-blk-test` (see G20 for the first) |
| The graphics gate | `make stage0-check` |
