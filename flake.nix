{
  description = "Guix GNU/Hurd guests for Hurdkit, built by goonix";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # goonix is our fork of GNU Guix. flake.lock pins the exact commit of it;
  # that pin is what replaces Guix channels and "guix pull" here. Our work is
  # on its goonix branch; its main branch mirrors upstream Guix.
  inputs.goonix.url = "github:hurdkit/goonix/goonix";

  outputs =
    { self, nixpkgs, goonix }:
    let
      # The guests are x86_64 virtual machines, and the image build runs
      # x86_64 Linux builders, so this is the only supported host.
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      # The `guix` command of the pinned goonix and the host tools of the
      # make targets. Building goonix takes a while the first time.
      devShells.${system}.default = pkgs.mkShell {
        name = "hurdkit-guix";

        packages = with pkgs; [
          goonix.packages.${system}.default # guix

          # --- the guests (scripts/guix_vm.sh) ---
          gnumake
          qemu # qemu-system-x86_64, qemu-img, qemu-nbd
          openssh # ssh, scp, ssh-keygen
          util-linux # flock, setsid, partx
          e2fsprogs # e2fsck, for the repair of a kept state
          libnbd # nbdfuse, for the same
          git
          gawk
          gnused
          gnugrep
          gnutar
          coreutils

          # The QEMU monitor client of guix_vm.sh, and the pinned driver
          # matrices, which run on the host and need pexpect.
          (python3.withPackages (ps: [ ps.pexpect ]))

          # --- graphics harness of the Hurd and Linux reference guests ---
          tcl # scripts/qmp.tcl and scripts/ppm_check.tcl
          tclPackages.tcllib # their JSON support
          socat # QMP over a Unix socket for scripts/qmp.tcl
          imagemagick # niri PNG -> PPM for accelerated screenshots
        ];

        shellHook = ''
          # nbdfuse (the repair of a kept state) mounts through the setuid
          # fusermount3. On NixOS that is the wrapper in /run/wrappers/bin;
          # the fusermount3 of the fuse3 package in the store is not setuid
          # and fails with "Operation not permitted". With the wrapper
          # directory first in PATH, whatever calls fusermount3 by name gets
          # the one that works.
          if [ -d /run/wrappers/bin ]; then
            export PATH="/run/wrappers/bin:$PATH"
          fi

          if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
            echo "hurdkit-guix: /dev/kvm is not usable, the guests will run without acceleration (slow)" >&2
          fi
        '';
      };
    };
}
