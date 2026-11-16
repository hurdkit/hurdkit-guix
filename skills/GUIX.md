# Skill: Build and Manage the Guix 64-bit GNU/Hurd Guest

## Trigger

Use this skill for work on the Guix guest (`guix/`, `guix.mk`,
`scripts/guix_*.sh`), or when a Guix guest does not boot or answer.

## Inputs

- `nix/flake.nix` and `nix/flake.lock`: the `guix` development shell, with
  goonix (our fork of GNU Guix) at a pinned commit.
- `guix/hurd64.scm`: the system declaration of the guest.
- `guix/goonix.scm`: goonix as the guest's own Guix (same commit as the lock).
- `guix.mk` and `scripts/guix_vm.sh`: build and lifecycle commands.
- `img/guix/`: the base image, overlays and logs of the guest.
- `img/keys/`: the root and peon SSH keys, shared with the Debian guest.

## Goal

Build and boot a 64-bit GNU/Hurd guest from a declarative Guix system,
with key-based SSH and safe disposable and persistent overlays. Nothing of
the Debian pipeline (its images, keys or scripts) is used or changed.

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

`guix system image` prints the image in the store: a read-only, compressed
qcow2. The first build on a machine cross-compiles goonix for the guest
(about 15 minutes with 16 cores); everything else is downloaded from the
build farm. Boot it without changing it:

```sh
qemu-system-x86_64 -M q35 -enable-kvm -m 2048 -snapshot -hda IMAGE \
    -device e1000,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2223-:2222 -nographic
ssh -i img/keys/root_ed25519 -p 2223 root@127.0.0.1 guix --version
```

The guest's `guix --version` prints the same goonix line as on the host.
`make guix-test` runs the TAP tests of `tests/`.

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

### Boot and manage the guest

```sh
make guix-image
make guix-start
make guix-ssh
make guix-ssh-peon
make guix-stop
```

`make guix-image` builds the image as above, converts it into
`img/guix/hurd64.base.qcow2` and creates the accounts' SSH keys in
`img/keys/` if the Debian provisioning has not; a second run reports that it
is up to date. It refuses a `guix` whose first `--version` line lacks
`goonix`.

`make guix-start` boots a disposable overlay of the base image, waits for a
successful SSH login on host port 2223 and retries a boot that does not
answer within 180 seconds, up to three boots (G15). `make guix-status` says
whether the guest runs and answers. `make guix-stop` sends `halt` over SSH,
waits for GNU Mach's shutdown marker in the serial log, then stops QEMU,
because a Hurd halt does not power the machine off (G16); about 20 seconds.
A forced stop without that marker returns failure.

### Rebuild and persistent state

Change the declaration, then `make guix-stop guix-image guix-start`.

`make guix-start-persist` keeps the disk in `img/guix/state.qcow2`, an
overlay of the current base image (G8). After an unclean stop, run
`make guix-repair`. `make guix-reset-state` deletes the kept state;
`make guix-image` refuses to replace the base while one exists.

### When a guest does not answer

Read `img/guix/serial-N.log` (`.serial-current` names the active boot;
`serial.log` keeps the last one after stop) and save the screen with
`make guix-screenshot` (`img/guix/screen.ppm`). `bash scripts/guix_vm.sh
monitor 'info pci'` talks to the QEMU monitor. A boot that times out gets a
fresh overlay; a kept state is repaired before the next attempt.

`make guix-test` runs the TAP tests of the scripts (`tests/*.t`); they boot
nothing and use fake QEMU, SSH and Guix commands. `tests/guix-packages.t`
evaluates every package and system declaration with goonix.

### Host archive signing

`guix/hurd64.scm` authorizes the host's archive signing key,
`/etc/guix/signing-key.pub`, when the host has one, so `guix copy` from the
host into the guest works. `make guix-authorize-host` creates a missing key
pair (the private key stays in `/etc/guix/signing-key.sec`); on NixOS
without `/run/wrappers/bin` in `PATH`, add
`GUIX_SUDO=/run/wrappers/bin/sudo`. An image built before the key existed
does not trust it: rebuild the image.

### Package modules, GNU Mach and Hurd variants

Packages of this repository are Guile modules under `guix/modules/hurdkit/`;
`guix_vm.sh` and the test scripts pass `-L guix/modules`. Build one with
`guix build -L guix/modules --target=x86_64-pc-gnu NAME`. A module that
does not compile breaks every image build: `make guix-test` (its
`guix-packages.t`) shows which. Never edit goonix for this, and never
change the guest's glibc: every package links against it, so a changed
glibc rebuilds the whole guest locally.

`(hurdkit packages hurd)` has GNU Mach and the Hurd at the commits the
toolchain builds: `gnumach-hurdkit` (Hurdkit's GNU Mach, with its
shared-interrupt fixes) and `hurd-hurdkit`. Guix needs fixed commits, while
`toolchain/pins.mk` follows the `hurdkit` branch of the GNU Mach fork: move
the commits in the module forward with it. `hurd-hurdkit` carries two
compatibility patches for goonix's older rumpkernel and GNU Mach headers,
and builds serially (G23).

`operating-system-with-hurd` from `(hurdkit system)` replaces the Hurd of a
system: the boot servers, and also `pfinet`, the console, getty and login,
whose services otherwise keep starting goonix's default Hurd. In such a
guest, `ps -ef` shows every translator from the one Hurd.

### Driver tests

Upstream's driver matrices (`scripts/virtio_test.py`,
`virtio_balloon_test.py`, `virtio_blk_test.py`) run unchanged in a Guix
guest:

```sh
make guix-virtio-test          # virtio-9p and 9pfs
make guix-virtio-balloon-test
make guix-virtio-blk-test
```

`scripts/guix_virtio_test.sh` builds `guix/hurd64-drivers.scm` (the guest
with Hurdkit's GNU Mach, the drivers and `setsid` and `poweroff`, which the
matrices expect from a Debian guest) into `img/guix-drivers/`, builds the
drivers (`hurdkit-virtio` at the commit `(hurdkit packages virtio)` pins,
and `hurd-9pfs`), boots the guest on port 2231 with the device and its
QEMU trace events, and runs the matrix. After a passing matrix the guest has
to shut down cleanly; after the 9p matrix it does not (G20), so
`make guix-virtio-test` fails at that point even when all assertions pass.
A failed matrix leaves the guest running and prints how to reach it;
`REUSE=1` runs the matrix again on that guest (after the 9p matrix, only
once its translators are gone). `VIRTIO_SRC=~/src/virtio` builds the drivers
from a local checkout instead.

The guest also has `9pfs` for a host directory over TCP: start
`python3 toolchain/9p-server.py DIR 127.0.0.1:1564` on the host (G21), then
`settrans -c /host "$(command -v 9pfs)" 10.0.2.2:1564` in the guest.

Binaries of hurdkit's standalone cross toolchain do not run in the Guix
guest: it has no `/lib/ld-x86-64.so.1`. Drivers are therefore Guix packages,
built against the guest's own libraries.

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

It uses host port 2224 and `img/guix-linux/`. `linux-ref-screenshot` takes
the picture through niri's IPC, because QMP `screendump` cannot read an
accelerated scanout. `make stage0-check` is the live gate: the Hurd guest
boots and stops cleanly, and for each GPU in `STAGE0_GPUS` (default `amd
nvidia`) and path (virgl, and Venus for `STAGE0_VENUS_GPUS`) the reference
reports that GPU as renderer, runs glmark2, takes screenshots, opens foot by
QMP keys and stops cleanly. Artifacts go to `img/stage0/`.

### niri platform guest

`make stage1-check` builds `guix/hurd64-platform.scm` (Hurdkit's GNU Mach,
`hurd-tmpfs-mapped`, the epoll shim and the platform's test programs) into
`img/guix-platform/`, boots it on port 2226 and runs in it:

- `tmpfs-shm /dev/shm 100`, and `/tmp` (ext2) as the control: mappings of
  unlinked files survive close, data survives write and read and remapping,
  a page beyond the end of the file faults, and space is given back;
- the TAP suites of `hurd-epoll-shim` (`hurd-epoll-shim-test-NAME`), the
  epoll, eventfd, timerfd and signalfd library for the libwayland port, which
  lives in its own repository, github.com/hurdkit/hurd-epoll-shim;
- `hurdkit-rust-hello` and the `hurdkit-rust-evloop` TAP test (calloop and
  polling on the Hurd).

`hurd-tmpfs-mapped` is `hurd-hurdkit` with
`guix/patches/hurd-tmpfs-keep-mapped.patch`: when the last reference to an
unlinked file goes away, tmpfs no longer shrinks its memory object to zero,
so the file's mappings keep working.

## Pitfalls

**G1. An image built by another Guix is a different system.** Another
`guix` can come first in `PATH`, for example one installed by `guix pull`
into `~/.config/guix/current`. Its package graph differs, so the image
differs from the declared one even with identical files. `guix_vm.sh image`
and `guix_virtio_test.sh` refuse a `guix` whose first `--version` line
lacks `goonix` (`GUIX_ANY_VERSION=1` overrides that for experiments).

**G2. Substitutes exist only for commits the build farm built.** GNU Mach,
the Hurd, glibc and the cross toolchain of the guest are downloaded
pre-built because goonix has the package definitions of an upstream Guix
commit that the farm built. A goonix commit that changes those definitions
makes Guix build a toolchain and a C library locally: hours. Check before a
long wait: `guix system image --dry-run --image-type=hurd64-qcow2
guix/hurd64.scm` lists configuration files, `goonix-…` and nothing named
`gcc-…`, `glibc-…`, `hurd-…` or `gnumach-…`. The variants of
`(hurdkit packages hurd)` are always built here (minutes).

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

**G7. The root filesystem is partition 1.** A Guix GNU/Hurd image has one
partition: `bash scripts/repair_filesystem.sh IMAGE 1`.

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
content, with about 200 MB free. Set `GUIX_IMAGE_OPTS := --image-size=8G`
when you need room.

**G13. Parallel heavy jobs make everything look hung.** Building goonix or
an image while a guest runs saturates the disk, and `nix develop` waits
silently on a store lock. Run heavy steps one after another; `cat
/proc/pressure/io` shows whether the disk is the bottleneck.

**G14. An open port is not a ready guest.** QEMU accepts the forwarded port
at once. Only a successful login proves the guest is up.

**G15. The guest sometimes hangs at boot, in the network setup.** Between a
fifth and a third of the boots sit idle after `Service file-systems has
been started.`; sshd never starts and SSH fails with `Connection timed out
during banner exchange`. A good boot prints `irq handler [11]: new delivery
port … for /hurd/netdde(…)` right after that line (netdde, the network card
driver, starting when `pfinet` opens `eth0`); a hung boot never does. The
cause is not known. `guix_vm.sh start` stops a boot without SSH after
`GUIX_BOOT_TIMEOUT` (180 s) and tries again, up to `GUIX_BOOT_ATTEMPTS` (3).

**G16. `halt` does not power the virtual machine off.** GNU Mach prints
`Shutdown completed successfully, now in tight loop.` on its console, which
the declaration puts on the serial line (`console=com0`), and QEMU keeps
running. `guix_vm.sh stop` waits for that line, then stops QEMU.

**G17. Ignore "Consider running 'guix pull'".** goonix has no channel
information, so `guix` prints it every time. See G1.

**G18. `guix system image --root=LINK` does not replace a link.** It fails
with `failed to create GC root`, so `guix_vm.sh image` removes the old link
first. A link renamed after the build no longer protects the image.

**G19. A Unix socket path has at most 107 bytes.** The monitor and QMP
sockets therefore live in `$XDG_RUNTIME_DIR`, named after the SSH port.

**G20. After 9pfs has been used, `halt` may not finish.** In guests in
which a 9pfs translator ran, sshd stops on `halt` but GNU Mach's shutdown
marker often never comes, also after `settrans -g`. The cause is not known.
`guix_vm.sh stop` stops QEMU after 60 seconds and exits nonzero; with a kept
state, run `make guix-repair` before the next persistent boot.

**G21. Mount 9pfs over TCP only after the server is up.** If 9pfs connects
before `toolchain/9p-server.py` listens, it exits and every access fails
with `Translator died`. Wait for `9p-server: serving …`, and after a dead
mount run `settrans -g -f /host` before mounting again.

**G22. The guest has no swap, and its default pager loses data.** A page of
a tmpfs file (or of anonymous memory) that leaves memory cannot be written
anywhere: the serial log shows `(default pager): data_return write error,
losing data`, and later accesses fault. GNU Mach can then fail
`vm_map_copyin_page_list: Assertion 'm->wire_count == 1'` and stop in its
debugger. `msync(MS_INVALIDATE)` on a tmpfs file triggers it, and so does
shrinking a mapped tmpfs file and growing it again (`tmpfs-shm
--truncate`), with goonix's Hurd and GNU Mach as with Hurdkit's.

**G23. The newer Hurd's `make -j` is racy.** `utils/` fails with `No rule to
make target 'auth_requestUser.stamp'`, often enough that `hurd-hurdkit`
builds serially: about four minutes instead of one.

## Verification

On 2026-11-16, with goonix `630ee30` on host, shell and guest:

- `make guix-test` passes all suites (they boot nothing), and
  `guix system image --image-type=hurd64-qcow2 guix/hurd64.scm` builds the
  image (`make guix-image` builds the same derivation).
- `make guix-image guix-start guix-ssh guix-ssh-peon guix-stop`:
  the guest's `guix --version` is `1.5.0-goonix.630ee30`, peon logs in with
  its key, the stop is clean and `make guix-status` then prints `stopped`.
  The network-setup hang of G15 hit several boots during the day; the retry
  recovered every one.
- `guix/hurd64-hurdkit.scm` builds, boots and stops cleanly, and
  `ps -ef` shows every Hurd server (auth, proc, pfinet, pflocal, term,
  random, startup) from `hurd-hurdkit`. `tests/guix-packages.t` evaluates all
  16 packages and declarations.
- `make guix-virtio-balloon-test` passes 22/22 and
  `make guix-virtio-blk-test` 24/24, each followed by a clean shutdown.
  `make guix-virtio-test` (9p) passes 24/24, then the guest does not halt
  (G20), so the target fails, as it should.
- The Hurd guest with the default `GUIX_GPU=none` boots, its
  VGA console is saved through QMP (`make guix-screenshot`, 640x400) and it
  stops cleanly (the first part of `make stage0-check`).
- `STAGE0_GPUS=nvidia STAGE0_VENUS_GPUS=nvidia make stage0-check`
  passes 12/12 (AMD was not part of this run). With virgl and with Venus,
  niri runs as peon on `virgl (NVIDIA GeForce RTX 3080 Laptop GPU/PCIe/SSE2)`
  and `Virtio-GPU Venus (NVIDIA GeForce RTX 3080 Laptop GPU)`, glmark2 runs,
  Super+T over QMP opens foot (55.6% of the screen changes) and the guest
  powers off cleanly. Ten seconds of the idle desktop, traced, contain no
  virtio-gpu command.
- On goonix's stock Hurd, `tmpfs-shm /dev/shm` fails cases 1 and 2
  (SIGBUS after close); with `hurd-tmpfs-mapped` all 6 cases pass on
  `/dev/shm` (100 cycles) and on ext2.
- `hurdkit-rust-hello` and the 8 assertions of `hurdkit-rust-evloop`
  pass in the platform guest.
- `make stage1-check` passes: tmpfs, the eventfd (46), epoll (67),
  timerfd (36) and signalfd (30) suites, with only the documented skips
  (`EPOLLRDHUP` on sockets, `CLOCK_BOOTTIME`, the signal sender), and the Rust
  tests; the guest then shuts down cleanly. All seven suites of the library
  passed five times in a row in the guest.
