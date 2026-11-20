# Guix GNU/Hurd guests for Hurdkit

64-bit GNU/Hurd systems declared with Guix and built by
[goonix](https://github.com/hurdkit/goonix), our fork of GNU Guix:

- a plain guest (`guix/hurd64.scm`);
- a guest on Hurdkit's GNU Mach and Hurd (`guix/hurd64-hurdkit.scm`);
- the released forms of those two, which have nothing of the machine that
  builds them (`guix/hurd64-release.scm`,
  `guix/hurd64-hurdkit-release.scm`);
- a disposable guest that runs the test matrices of Hurdkit's virtio
  drivers (`guix/hurd64-drivers.scm`);
- the guests of the Wayland and niri work with their gates
  (`guix/hurd64-platform.scm`, `guix/hurd64-wayland.scm`), and a Linux
  reference guest for the graphics harness (`guix/linux-reference.scm`).

Nothing here is built from a checkout of another repository. GNU Mach, the
Hurd, the virtio drivers, their test matrices and hurd-epoll-shim are Guix
packages at pinned commits, in `guix/modules/hurdkit/packages/`. A pin
moves only when someone moves it.

## Quick start

```sh
nix develop                  # the pinned goonix and the host tools
make guix-test               # scripts and declarations; boots nothing
make guix-image guix-start   # build the plain guest, boot it, wait for SSH
make guix-ssh                # a root shell in it
make guix-stop
```

`make help` lists the targets. [skills/GUIX.md](skills/GUIX.md) is the
guide: the host's Guix daemon, the image build, the guests and their
gates, and the pitfalls. The host's daemon has to be goonix too; the guide
says how.

## Released images

A pushed tag `v*` is built on GitHub's runners and published as a release
of this repository: the released guests as compressed qcow2 files,
their checksums, and notes that name the pins and give the QEMU command.
Their root has an empty password, as in upstream Guix's bare-hurd template,
so forward their SSH port from `127.0.0.1` only. The "Release images"
section of the guide says how they are built and checked.

## Layout

```
flake.nix, flake.lock   # development shell with goonix at a pinned commit
.github/workflows/      # the release images and the tests on GitHub
Makefile                # the make targets
guix/                   # system declarations, package modules, patches
scripts/                # build, boot and manage the guests; the gates
tests/                  # TAP tests of the scripts, and the test programs
                        # that the guests run
skills/GUIX.md          # the guide
img/                    # images, logs and SSH keys (created, not tracked)
```

## What belongs where

- Here: Scheme (system declarations and package modules) and what serves
  only these guests.
- A fix to the source of GNU Mach, the Hurd, a driver or hurd-epoll-shim:
  a pull request to that source's repository under
  [hurdkit](https://github.com/hurdkit). The pin moves here once it is
  merged.
- A test or a tool that does not need Guix: the
  [hurdkit](https://github.com/hurdkit/hurdkit) repository. It is pinned
  here; `tests/hurd/tmpfs-shm.c` is an example.

## License

The GNU General Public License, version 3, as the Hurdkit repository that
these files come from. See [LICENSE](LICENSE).
