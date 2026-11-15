# Guix GNU/Hurd (x86_64-gnu) guest. Included by the top-level Makefile.
#
# The system is declared in guix/hurd64.scm; scripts/guix_vm.sh builds,
# boots and manages it. Run these targets inside "nix develop ./nix#guix":
# the guix command has to be the pinned goonix.

# The system declaration that guix-image builds.
GUIX_OS         := guix/hurd64.scm
# The port on the host that is forwarded to the sshd of the guest. The
# Debian guest uses SSH_PORT (2222), so both guests can run together.
GUIX_SSH_PORT   := 2223
# Memory of the guest in MiB.
GUIX_MEMORY     := 2048
# Extra options for "guix system image", for example --image-size=8G
GUIX_IMAGE_OPTS :=

GUIX_VM := env GUIX_OS="$(abspath $(GUIX_OS))" \
	GUIX_SSH_PORT=$(GUIX_SSH_PORT) GUIX_MEMORY=$(GUIX_MEMORY) \
	GUIX_IMAGE_OPTS="$(GUIX_IMAGE_OPTS)" SSH_HOST=$(SSH_HOST) \
	SSH_KEY_DIR="$(abspath $(SSH_KEY_DIR))" \
	GUIX_DIR="$(abspath $(IMG_DIR)/guix)" \
	QEMU_SYSTEM=$(QEMU_SYSTEM) QEMU_IMG=$(QEMU_IMG) \
	bash scripts/guix_vm.sh

.PHONY: guix-image guix-start guix-start-persist guix-status guix-ssh \
	guix-ssh-peon guix-stop guix-screenshot guix-run guix-repair \
	guix-reset-state guix-authorize-host guix-virtio-test

# Build guix/hurd64.scm into img/guix/hurd64.base.qcow2
guix-image:
	@$(GUIX_VM) image

# Boot in the background from a throw-away overlay and wait for SSH
guix-start:
	@$(GUIX_VM) start

# The same, but the disk state is kept in img/guix/state.qcow2
guix-start-persist:
	@$(GUIX_VM) start persist

guix-status:
	@$(GUIX_VM) status

guix-ssh:
	@$(GUIX_VM) ssh root

guix-ssh-peon:
	@$(GUIX_VM) ssh peon

# Shut the guest down
guix-stop:
	@$(GUIX_VM) stop

# Save the VGA console of the running guest as img/guix/screen.ppm
guix-screenshot:
	@$(GUIX_VM) screenshot

# Boot in the foreground, console on this terminal, throw-away overlay
guix-run:
	@$(GUIX_VM) run

# Check and repair the root filesystem of the kept state (guest stopped)
guix-repair:
	@$(GUIX_VM) repair

# Delete the kept state
guix-reset-state:
	@$(GUIX_VM) reset-state

# Run the upstream virtio-9p matrix in a separate disposable Guix guest.
# This needs the pinned goonix shell and the local ~/src/virtio checkout.
# Failure retains the diagnostic directory and serial log; no Debian image
# is used. Shutdown without the Mach marker is a failed gate, even if I/O passes.
guix-virtio-test:
	@GUIX_DIR="$(abspath $(IMG_DIR)/guix/virtio-test)" REUSE="$(REUSE)" \
		bash scripts/guix_virtio_test.sh

# Generate the host archive-signing key if needed and trust its public half.
# SUDO=... is needed on NixOS when /run/wrappers/bin is not in PATH.
SUDO ?= sudo
guix-authorize-host:
	@bash scripts/guix_authorize_host.sh "$(SUDO)"
