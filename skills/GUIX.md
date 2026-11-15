# Skill: Build and Manage the Guix 64-bit GNU/Hurd Guest

## Trigger

Use this skill for work on the Guix guest (`guix/`, `guix.mk`,
`scripts/guix_vm.sh`), or when a Guix guest does not boot or answer.

## Inputs

- `nix/flake.nix` and `nix/flake.lock`: the pinned goonix development shell.
- `guix/hurd64.scm`: the system declaration.
- `guix/hurd64-drivers.scm` and `guix/9pfs.scm`: the optional driver guest.
- `guix.mk` and `scripts/guix_vm.sh`: build and lifecycle commands.
- `img/guix/`: the Guix base image, overlays and logs.
- `img/keys/`: the same root and peon SSH keys used by the Debian guest.

## Goal

Build and boot a 64-bit GNU/Hurd guest from a declarative Guix system,
with working key-based SSH, safe disposable and persistent overlays, and
Guix-built drivers. Do not modify the Debian image, its keys, or the host
NixOS configuration as part of these commands.

## Procedure

### Build and boot

Run all Guix commands in the pinned shell. Check that the first version line
contains `goonix`; never run `guix pull` for this project.

```sh
nix develop ./nix#guix
make guix-image
make guix-start
make guix-ssh
make guix-ssh-peon
make guix-stop
```

`make guix-image` prints the store image and
`img/guix/hurd64.base.qcow2`; a second run reports that it is up to date.
`make guix-start` waits for a successful SSH login on host port 2223 and
retries a boot that does not answer within 180 seconds, up to three boots.
`make guix-status` reports whether the guest is running and SSH answers.
`make guix-stop` sends `halt` with a bounded SSH control channel, waits for
GNU Mach's shutdown marker in the active boot's serial log, then stops QEMU
because a Hurd halt does not power off the virtual machine. A forced stop
without that marker returns failure; it is not a clean shutdown.

### Rebuild and persistent state

Change the declaration, then rebuild and boot a new system:

```sh
make guix-stop
make guix-image
make guix-start
```

To retain the disk across boots, use `make guix-start-persist`. The state is
`img/guix/state.qcow2`, an overlay tied to the current base. Copy data out
before replacing the base. After an unclean stop, run `make guix-repair`.
`make guix-reset-state` deletes the kept state after the guest is stopped.
`make guix-image` refuses to replace the base while a kept state exists.

For a guest that does not answer, inspect `img/guix/serial-N.log` and use
`make guix-screenshot` to save the VGA console as `img/guix/screen.ppm`.
`.serial-current` names the active attempt; `serial.log` is preserved after
stop. Every timed-out disposable boot gets a fresh overlay. Persistent retries
retain their state and repair it before the next attempt.

### Host archive signing

The guest declaration carries the public host signing key. The private key
stays at `/etc/guix/signing-key.sec` and is never copied into the repository.
Run `make guix-authorize-host` to create a missing host key pair or authorize
its public half. On NixOS, provide the wrapper path if needed, for example
`make guix-authorize-host SUDO=/run/wrappers/bin/sudo`. An existing key pair
that differs from `guix/host-signing-key.pub` is refused rather than replaced.

### Build and test 9pfs

The Guix guest has no `/lib/ld-x86-64.so.1`; a binary built by hurdkit's
standalone cross toolchain therefore cannot run there unchanged. Build the
driver with Guix so it uses the guest's libraries:

```sh
guix build --target=x86_64-pc-gnu -f guix/9pfs.scm
file "$(guix build --target=x86_64-pc-gnu -f guix/9pfs.scm)/bin/9pfs"
make guix-image GUIX_OS=guix/hurd64-drivers.scm
make guix-start GUIX_OS=guix/hurd64-drivers.scm
bash scripts/guix_vm.sh ssh root 'command -v 9pfs; 9pfs --version'
```

The binary must be a 64-bit GNU/Hurd ELF with an interpreter under
`/gnu/store`; the smoke test prints `9pfs 0.1.0`.

Start the existing host server and wait for its `serving` line before mounting:

```sh
mkdir -p ~/work/9p-root
echo "hello from the host" > ~/work/9p-root/canary.txt
python3 toolchain/9p-server.py ~/work/9p-root 127.0.0.1:1564
```

In another terminal:

```sh
bash scripts/guix_vm.sh ssh root 'settrans -c /host "$(command -v 9pfs)" 10.0.2.2:1564'
bash scripts/guix_vm.sh ssh root 'ls -la /host; cat /host/canary.txt'
bash scripts/guix_vm.sh ssh root 'echo "written from the guest" > /host/write-test.txt'
cat ~/work/9p-root/write-test.txt
bash scripts/guix_vm.sh ssh root 'settrans -g -f /host; rm -f /host'
```

The guest must read the canary and write a file visible on the host. Stop the
host server afterward. A host-side SSH timeout does not by itself prove that
a translator failed; inspect `ps -x` and the mount inside the guest.

## Pitfalls

**G1. `guix` outside the development shell is not goonix.** The host also
has a system-wide Guix (it runs the daemon). Outside `nix develop ./nix#guix`,
`guix --version` prints `1.5.0-unstable-…` (or whatever a `guix pull` put
into `~/.config/guix/current`), and an image built with it is not the
image the flake pins. Check the first line of `guix --version`; it must
contain `goonix`. Never run `guix pull` for this work.

**G2. Substitutes exist only for commits the build farm built.** Everything
heavy in the guest (GNU Mach, the Hurd, glibc, the cross toolchain) is
downloaded pre-built. That works because goonix has the same package
definitions as the upstream commit named in section 2 of the plan. If the pin
is moved to a goonix commit that changes package definitions, or to an upstream
commit that was never built, Guix cross-compiles a toolchain and a C
library locally: hours instead of minutes. Check before a long wait:
`guix system image --dry-run --image-type=hurd64-qcow2 guix/hurd64.scm`
lists what would be built and how much would be downloaded. A healthy run
builds about 50 derivations with names like `shepherd-….scm`,
`sshd_config`, `grub.cfg`, `partition.img`, `disk-image`, and none named
`gcc-…`, `glibc-…`, `hurd-…` or `gnumach-…`.

**G3. Our image cannot itself be downloaded, and its store path differs
from the build farm's.** The store path of an image depends on its exact
derivation. The build farm computes the reference image with a Guix that
was installed through channels; goonix is installed through Nix, and the
derivation of the image differs. This is harmless: the packages inside are
identical and are still downloaded. Fetch the reference image by its store
path, not by rebuilding its expression.

**G4. The image build needs `/tmp` on ext4.** While it populates the root
filesystem, Guix records each Hurd translator (`/dev` nodes, `/servers`)
as a `gnu.translator` extended attribute on a file in the build directory
of the daemon, under `/tmp`. Linux accepts `gnu.*` attributes on ext4
only. On tmpfs or btrfs the build log shows `Operation not supported`
followed by `Ignoring...Good Luck!` for each of them, the build still
"succeeds", and the guest does not come up. Check `findmnt -no FSTYPE -T /tmp`
before building, and search the build output for `Good Luck` after.

**G5. sshd in the guest listens on 2222, not 22.** The port forward has to
end in `-:2222`. With `-:22` the connection is accepted by QEMU and reset
by the guest, exactly like a guest that is still booting.

**G6. The 64-bit guest needs `-M q35`.** With QEMU's default machine type
the 64-bit Hurd has problems with memory; Guix's own VM service passes
`-M q35` for the `hurd64` image type and so does `scripts/guix_vm.sh`.

**G7. The root filesystem is partition 1.** A Guix GNU/Hurd image has one
partition; the Debian image has swap first and root second. Offline tools
therefore take `1`: `bash scripts/repair_filesystem.sh IMAGE 1`.

**G8. A kept state is tied to one base image.** `img/guix/state.qcow2` is
a copy-on-write overlay: it stores only the blocks that differ from
`hurd64.base.qcow2`. Replace the base image and the overlay describes
changes to a disk that no longer exists; the guest sees a corrupt
filesystem. `guix_vm.sh image` refuses to run while a kept state exists.
Remove it first (`make guix-reset-state`); what you need from it has to
be copied out with `scp` before.

**G9. Nix only sees files that git knows.** After editing `nix/flake.nix`, run
`git add nix/flake.nix nix/flake.lock` before `nix develop`. Otherwise Nix
evaluates the old file, or fails with "path … is not tracked by Git".
(`guix/hurd64.scm` is read by Guix from the working directory, not through
Nix, so this does not apply to it.)

**G10. The store image is read-only and compressed.** The file that
`guix system image` prints lives in `/gnu/store`: it cannot be written,
it is zstd-compressed qcow2, and `guix gc` deletes it unless a root points
at it. `guix_vm.sh image` therefore passes `--root=` (the symlink
`img/guix/hurd64.store-image`) and converts the image into
`img/guix/hurd64.base.qcow2`. Never boot the store file without
`-snapshot`.

**G11. The guest has little free disk space by default.** The image is
sized to its content: about 1.7 GB with roughly 200 MB free. That is
enough to boot and log in, not to install or build anything inside. Set
`GUIX_IMAGE_OPTS := --image-size=8G` in `guix.mk` when you need room.

**G12. The interactive shell on this machine is zsh, with traps.** `cp`
and `mv` are aliased to ask before overwriting, so a command line with
`cp a b` over an existing file waits for an answer forever when there is
no terminal: use `command cp -f`. `noclobber` is set, so `> FILE` on an
existing file fails with `file exists` and the command that was meant to
write it silently uses the old content: write files with an editor, or
with `>|`. zsh also reads `$var:rest` as a modifier on `$var`
(`$sha:refs/heads/main` loses characters): write `${sha}:refs/…`.
Anything longer than a line belongs in a bash script, run with `bash`.

**G13. Parallel heavy jobs make everything look hung.** Building goonix,
building an image and running a guest at the same time saturate the disk;
`nix develop` then waits silently on a store lock for minutes. Run the
heavy steps one after another, and before concluding that something hangs
look at `cat /proc/pressure/io` (a `full avg10` above 40 means the disk
is the bottleneck).

**G14. An open port is not a ready guest.** QEMU accepts the forwarded port
at once and resets the connection until sshd runs. Only a successful login
proves the guest is up; `guix_vm.sh start` waits for exactly that.

**G15. The 64-bit guest sometimes hangs at boot, in the network setup.**
Two of eleven boots in the original investigation stopped at
`shepherd[1]: Starting service networking...`: the `loopback` and
`networking` services never finish, so sshd never starts, and the guest
sits idle at about 1% CPU. The cause was not found; both services start
`pfinet`, the Hurd's TCP/IP server. `guix_vm.sh start` stops a boot without
SSH after `GUIX_BOOT_TIMEOUT` (180 seconds) and retries up to
`GUIX_BOOT_ATTEMPTS` (3) times, checking a kept state with `e2fsck` between
attempts. The retry has not been verified in action. If all attempts hang,
retain `img/guix/serial.log` and a screenshot. Do not describe this as fixed
without a guest-level reproduction and root-cause evidence.

**G16. `halt` does not power the virtual machine off.** The Hurd shuts
down, GNU Mach prints `Shutdown completed successfully, now in tight
loop.` on its console, and QEMU keeps running. Waiting for QEMU to exit
therefore always runs into the timeout. `guix_vm.sh stop` waits for that
line in `img/guix/serial.log` instead and stops QEMU when it appears;
this is why the declaration puts the console on the serial line
(`console=com0`).

**G17. Ignore the "Consider running 'guix pull'" warning.** Every
`guix system image` prints it, because goonix is newer than its own
release date suggests and has no channel information. It does not mean
anything is out of date. See G1: never run `guix pull` for this work.

**G18. `guix system image --root=LINK` does not replace an existing link.**
It fails with `failed to create GC root`. `guix_vm.sh image` removes the
old link first. Do not "fix" it by building into a temporary link and
renaming it: Guix registers the root under the path given to `--root`,
and a renamed link no longer protects the image from `guix gc`.

**G19. A Unix socket path is limited to 107 bytes.** QEMU refuses
`-monitor unix:PATH` with `UNIX socket path must be less than 108 bytes`
when the checkout lives in a deep directory. `guix_vm.sh` therefore puts
the monitor socket into `$XDG_RUNTIME_DIR` (`/run/user/UID`), named after
the SSH port, not into `img/guix/`.

**G20. After 9pfs has been used, `halt` may not finish.** In the original
investigation, three of three guests in which a 9pfs translator had run
stopped their SSH server on `halt` and did not reach GNU Mach's shutdown
marker, including after `settrans -g`; five shutdowns without 9pfs were clean.
The cause was not found. A later reference-image control with a mounted 9pfs
translator did reach the marker, so the symptom is not universal and the
difference is unresolved. `guix_vm.sh stop` stops QEMU after 60 seconds and
says so. With a throw-away disk nothing is lost; with a kept state, run
`make guix-repair` before the next `make guix-start-persist`.

**G21. Start the 9P server before mounting, and wait for it.** If the
guest connects before `9p-server.py` listens, 9pfs exits at once and every
access to the mount point fails with `Translator died`. On a loaded host
Python can take seconds to start. Wait for its line
`9p-server: serving … on 127.0.0.1:1564`, and if a mount already died,
`settrans -g -f /host` and mount again.

### Virtio-9p diagnostics

Use the upstream `scripts/virtio_test.py` assertions through the Guix wrapper:
`make guix-virtio-test` inside `nix develop ./nix#guix`. It builds the Guix
`9pfs` and `virtio-9p` packages, boots a disposable guest on port 2231 with
an optional virtio device, and runs the device, mount, I/O, teardown, and
recreation matrix. The driver source is the existing `~/src/virtio` checkout.
The diagnostic directory is `img/guix/virtio-test`; it must not already exist.
On failure, retain its `serial.log` and use `scripts/guix_vm.sh mode` to query
the QEMU monitor. `VIRTIO_ADDR=0x5` is the isolated-IRQ control; do not infer
a Hurd boot fix from a driver or IRQ result.

The pinned guest passed the 24-assertion virtio I/O matrix on 2026-11-15.
One run's halt did not reach the Mach shutdown marker within 60 seconds;
`guix stop` and the wrapper correctly returned failure. A later controlled run
passed the same matrix and shut down cleanly. The earlier symptom is therefore
intermittent, not a failure of every virtio-9p guest. The ordinary boot never
attaches the virtio device.

Set `GUIX_BASE_IMG` to an explicit base for a diagnostic variant. Relative
paths are resolved before the wrapper links the base into its temporary
`GUIX_DIR`. Use `VIRTIO_STORE` and `P9FS_STORE` for packages built against
that guest's Hurd libraries; their interpreter and library closure must be
present in the guest. The opt-in image includes its diagnostic packages for
this reason. These packages are not boot-critical services.

The opt-in `guix/hurd-upstream.scm` package and `guix/hurd64-upstream.scm`
guest are diagnostics, not a replacement for the reference pin. The selected
Hurd revision is `881e887bfc45e61ab08adace04faa32d1711526d`. The complete
image is built with the pinned toolchain:

```sh
nix develop ./nix#guix -c env \
    GUIX_DIR="$PWD/img/guix/upstream-complete" \
    GUIX_OS="$PWD/guix/hurd64-upstream.scm" GUIX_SSH_PORT=2230 \
    bash scripts/guix_vm.sh image
```

The declaration replaces the network service's `pfinet` path as well as the
boot servers. The verified no-device control used the newer `pfinet`, reached
SSH, and shut down cleanly. Its controlled virtio run passed all 24 assertions
and shut down cleanly. These successful runs do not establish a statistical
fix for the intermittent `pfinet` boot stall.

## Current verification limits

- The pinned shell and both `hurd64` image types are verified.
- The base image and 9pfs driver build, and both accounts accept their keys.
- The 9pfs canary read and host-visible write are verified in a custom guest.
- A managed 9pfs guest completed `make guix-stop` both with the translator
  mounted and after detaching it. The older mounted-hang symptom was not
  reproduced in those runs; its cause is still unresolved.
- The original `pfinet` boot hang and 9pfs shutdown correlation are not
  root-caused. No Hurd or 9pfs source fix is established by the successful
  controls above.
- The Debian virtio control reached login and detected the device, but did not
  complete a successful mount matrix. The passing Guix matrix does not prove
  that the Debian provisioning or driver control passes.
- Hurd startup reports `startup: shutdown: No such file or directory` when
  `/servers/shutdown` is absent. A test-only one-shot service installed that
  translator, but the subsequent stop timed out before Hurd shutdown
  notifications. That experiment was reverted and is not a verified fix.
  After reverting it, the default guest again passed the normal start and
  clean stop sequence.
