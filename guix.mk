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
# Stage 0 graphics options. none leaves the existing Hurd guest unchanged.
GUIX_GPU        ?= none
GUIX_DISPLAY    ?= none
GUIX_TRACE      ?=
GUIX_TRACE_FILE ?=
GPU             ?=
GUIX_CPUS       ?= 4
GUIX_VENUS_MEMFD ?= 0
# Optional host Vulkan PCI vendor:device selection for Venus. QEMU's
# egl-headless rendernode selects the GL renderer, not the Vulkan server.
GPU_VK_DEVICE ?=
# Additional QEMU arguments after --, as a shell word list. Keep managed
# options (network, disk, QMP, monitor, serial and daemonize) in guix_vm.sh.
GUIX_QEMU_ARGS ?=
# Optional one-argument remote command, e.g. SSH_COMMAND='bash -s'.
# For compound commands pipe a script into linux-ref-ssh instead.
SSH_COMMAND ?=

GUIX_VM := env GUIX_OS="$(abspath $(GUIX_OS))" \
	GUIX_SSH_PORT=$(GUIX_SSH_PORT) GUIX_MEMORY=$(GUIX_MEMORY) \
	GUIX_IMAGE_OPTS="$(GUIX_IMAGE_OPTS)" SSH_HOST=$(SSH_HOST) \
	SSH_KEY_DIR="$(abspath $(SSH_KEY_DIR))" \
	GUIX_DIR="$(abspath $(IMG_DIR)/guix)" \
	GUIX_GPU="$(GUIX_GPU)" GUIX_DISPLAY="$(GUIX_DISPLAY)" \
	GUIX_TRACE="$(GUIX_TRACE)" GUIX_TRACE_FILE="$(GUIX_TRACE_FILE)" \
	GPU="$(GPU)" GPU_VK_DEVICE="$(GPU_VK_DEVICE)" GUIX_CPUS="$(GUIX_CPUS)" GUIX_VENUS_MEMFD="$(GUIX_VENUS_MEMFD)" \
	QEMU_SYSTEM=$(QEMU_SYSTEM) QEMU_IMG=$(QEMU_IMG) \
	bash scripts/guix_vm.sh

.PHONY: guix-image guix-start guix-start-persist guix-status guix-ssh \
	guix-ssh-peon guix-stop guix-screenshot guix-run guix-repair \
	guix-reset-state guix-authorize-host guix-virtio-test guix-qmp \
	linux-ref-image linux-ref-start linux-ref-stop linux-ref-status \
	linux-ref-ssh linux-ref-ssh-peon linux-ref-screenshot linux-ref-qmp \
	stage0-check stage0-harness-check

# Build guix/hurd64.scm into img/guix/hurd64.base.qcow2
guix-image:
	@$(GUIX_VM) image

# Boot in the background from a throw-away overlay and wait for SSH
guix-start:
	@$(GUIX_VM) start -- $(GUIX_QEMU_ARGS)

# The same, but the disk state is kept in img/guix/state.qcow2
guix-start-persist:
	@$(GUIX_VM) start persist

guix-status:
	@$(GUIX_VM) status

guix-ssh:
	@$(GUIX_VM) ssh root $(if $(SSH_COMMAND),"$(SSH_COMMAND)")

guix-ssh-peon:
	@$(GUIX_VM) ssh peon $(if $(SSH_COMMAND),"$(SSH_COMMAND)")

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

# Send a QMP command to the running Hurd or Linux reference guest.
guix-qmp:
	@$(GUIX_VM) qmp $(QMP_ARGS)

# The Linux guest uses the same build/lifecycle implementation with its own
# image basename, directory, SSH forwarding port and shutdown semantics.
LINUX_REF_VM := env GUIX_OS="$(abspath guix/linux-reference.scm)" \
	GUIX_IMAGE_TYPE=qcow2 GUIX_IMAGE_BASENAME=linux-reference \
	GUIX_IMAGE_OPTS="--image-size=8G" GUIX_GUEST_KIND=linux \
	GUIX_DIR="$(abspath $(IMG_DIR)/guix-linux)" GUIX_SSH_PORT=2224 \
	GUIX_MEMORY=4096 GUIX_CPUS="$(GUIX_CPUS)" GUIX_ROOT_PARTITION=2 \
	SSH_HOST=$(SSH_HOST) SSH_KEY_DIR="$(abspath $(SSH_KEY_DIR))" \
	GUIX_GPU="$(GUIX_GPU)" GUIX_DISPLAY="$(GUIX_DISPLAY)" \
	GUIX_TRACE="$(GUIX_TRACE)" GUIX_TRACE_FILE="$(GUIX_TRACE_FILE)" \
	GPU="$(GPU)" GPU_VK_DEVICE="$(GPU_VK_DEVICE)" GUIX_VENUS_MEMFD="$(GUIX_VENUS_MEMFD)" \
	QEMU_SYSTEM=$(QEMU_SYSTEM) QEMU_IMG=$(QEMU_IMG) bash scripts/guix_vm.sh

linux-ref-image:
	@$(LINUX_REF_VM) image
linux-ref-start:
	@$(LINUX_REF_VM) start -- $(GUIX_QEMU_ARGS)
linux-ref-stop:
	@$(LINUX_REF_VM) stop
linux-ref-status:
	@$(LINUX_REF_VM) status
linux-ref-ssh:
	@$(LINUX_REF_VM) ssh root $(if $(SSH_COMMAND),"$(SSH_COMMAND)")
linux-ref-ssh-peon:
	@$(LINUX_REF_VM) ssh peon $(if $(SSH_COMMAND),"$(SSH_COMMAND)")
linux-ref-screenshot:
	@$(LINUX_REF_VM) screenshot
linux-ref-qmp:
	@$(LINUX_REF_VM) qmp $(QMP_ARGS)

stage0-harness-check:
	@bash tests/guix-qemu-options.t
	@bash tests/qmp.t
	@bash tests/linux-screenshot.t
	@bash tests/ppm-check.t
	@bash tests/guix-vm-retry.t
	@bash tests/linux-stop.t
	@bash tests/guix-virtio-lifecycle.t

stage0-check:
	@bash scripts/stage0_check.sh

# Generate the host archive-signing key if needed and trust its public half.
# SUDO=... is needed on NixOS when /run/wrappers/bin is not in PATH.
SUDO ?= sudo
guix-authorize-host:
	@bash scripts/guix_authorize_host.sh "$(SUDO)"
