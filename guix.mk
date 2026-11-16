# Guix GNU/Hurd (x86_64-gnu) guest. Included by the top-level Makefile.
#
# The system is declared in guix/hurd64.scm; scripts/guix_vm.sh builds,
# boots and manages it. Run these targets inside "nix develop ./nix#guix":
# the guix command has to be the pinned goonix. See skills/GUIX.md.
#
# Every variable here starts with GUIX_ or LINUX_REF_, so that nothing
# collides with the Debian pipeline's variables in the Makefile.

# The system declaration that guix-image builds.
GUIX_OS          ?= guix/hurd64.scm
# The port on the host that is forwarded to the sshd of the guest. The
# Debian guest uses SSH_PORT (2222), so both guests can run together.
GUIX_SSH_PORT    ?= 2223
# Memory of the guest in MiB.
GUIX_MEMORY      ?= 2048
# Extra options for "guix system image", for example --image-size=8G
GUIX_IMAGE_OPTS  ?=
# Extra QEMU arguments for guix-start, as a shell word list.
GUIX_QEMU_ARGS   ?=
# One remote command for guix-ssh; pipe a script into it for more.
GUIX_SSH_COMMAND ?=
# Arguments of guix-qmp, e.g. GUIX_QMP_ARGS=status (see scripts/qmp.tcl).
GUIX_QMP_ARGS    ?=
# Graphics (skills/GUIX.md). The defaults leave the guest headless.
# GUIX_GPU: none, 2d, virgl, venus or nctx; GUIX_DISPLAY: none,
# egl-headless or gtk; GUIX_HOST_GPU: amd or nvidia, the host GPU that
# renders for egl-headless and Venus.
GUIX_GPU         ?= none
GUIX_DISPLAY     ?= none
GUIX_HOST_GPU    ?=
GUIX_VK_DEVICE   ?=
GUIX_VENUS_MEMFD ?= 0
# QEMU trace event pattern and file, e.g. GUIX_TRACE='virtio_gpu_cmd_*'
GUIX_TRACE       ?=
GUIX_TRACE_FILE  ?=
# Virtual CPUs; empty means QEMU's default of one.
GUIX_CPUS        ?=
# The command that runs guix-authorize-host as root.
GUIX_SUDO        ?= sudo

GUIX_VM_ENV = SSH_HOST=$(SSH_HOST) SSH_KEY_DIR="$(abspath $(SSH_KEY_DIR))" \
	QEMU_SYSTEM=$(QEMU_SYSTEM) QEMU_IMG=$(QEMU_IMG) \
	GUIX_GPU="$(GUIX_GPU)" GUIX_DISPLAY="$(GUIX_DISPLAY)" \
	GUIX_HOST_GPU="$(GUIX_HOST_GPU)" GUIX_VK_DEVICE="$(GUIX_VK_DEVICE)" \
	GUIX_VENUS_MEMFD="$(GUIX_VENUS_MEMFD)" \
	GUIX_TRACE="$(GUIX_TRACE)" GUIX_TRACE_FILE="$(GUIX_TRACE_FILE)"

GUIX_VM := env $(GUIX_VM_ENV) GUIX_OS="$(abspath $(GUIX_OS))" \
	GUIX_SSH_PORT=$(GUIX_SSH_PORT) GUIX_MEMORY=$(GUIX_MEMORY) \
	GUIX_CPUS="$(GUIX_CPUS)" GUIX_IMAGE_OPTS="$(GUIX_IMAGE_OPTS)" \
	GUIX_DIR="$(abspath $(IMG_DIR)/guix)" \
	bash scripts/guix_vm.sh

.PHONY: guix-image guix-start guix-start-persist guix-status guix-ssh \
	guix-ssh-peon guix-stop guix-run guix-repair guix-reset-state \
	guix-screenshot guix-qmp guix-authorize-host guix-test \
	guix-virtio-test guix-virtio-balloon-test guix-virtio-blk-test \
	linux-ref-image linux-ref-start linux-ref-stop linux-ref-status \
	linux-ref-ssh linux-ref-ssh-peon linux-ref-screenshot linux-ref-qmp \
	stage0-check stage1-check

# Build guix/hurd64.scm into img/guix/hurd64.base.qcow2
guix-image:
	@$(GUIX_VM) image

# Boot in the background from a throw-away overlay and wait for SSH
guix-start:
	@$(GUIX_VM) start -- $(GUIX_QEMU_ARGS)

# The same, but the disk state is kept in img/guix/state.qcow2
guix-start-persist:
	@$(GUIX_VM) start persist -- $(GUIX_QEMU_ARGS)

guix-status:
	@$(GUIX_VM) status

guix-ssh:
	@$(GUIX_VM) ssh root $(if $(GUIX_SSH_COMMAND),"$(GUIX_SSH_COMMAND)")

guix-ssh-peon:
	@$(GUIX_VM) ssh peon $(if $(GUIX_SSH_COMMAND),"$(GUIX_SSH_COMMAND)")

# Shut the guest down
guix-stop:
	@$(GUIX_VM) stop

# Boot in the foreground, console on this terminal, throw-away overlay
guix-run:
	@$(GUIX_VM) run

# Check and repair the root filesystem of the kept state (guest stopped)
guix-repair:
	@$(GUIX_VM) repair

# Delete the kept state
guix-reset-state:
	@$(GUIX_VM) reset-state

# Save the guest's display as img/guix/screen.ppm
guix-screenshot:
	@$(GUIX_VM) screenshot

# Send a QMP command to the running guest
guix-qmp:
	@$(GUIX_VM) qmp $(GUIX_QMP_ARGS)

# Generate the host's archive-signing key if needed and trust its public
# half. On NixOS without /run/wrappers/bin in PATH:
# GUIX_SUDO=/run/wrappers/bin/sudo
guix-authorize-host:
	@bash scripts/guix_authorize_host.sh "$(GUIX_SUDO)"

# The TAP tests of the scripts; no guest is booted.
guix-test:
	@set -e; for test in tests/*.t; do echo "# $$test"; bash "$$test"; done

# Upstream's driver matrices (scripts/virtio_*_test.py) in a separate,
# disposable Guix guest (guix/hurd64-drivers.scm, img/guix-drivers/).
# REUSE=1 reruns a matrix on the guest a failed run left running.
guix-virtio-test:
	@REUSE="$(REUSE)" bash scripts/guix_virtio_test.sh 9p

guix-virtio-balloon-test:
	@REUSE="$(REUSE)" bash scripts/guix_virtio_test.sh balloon

guix-virtio-blk-test:
	@REUSE="$(REUSE)" bash scripts/guix_virtio_test.sh blk

# The Linux niri reference guest (guix/linux-reference.scm): the same
# lifecycle with its own image, directory and SSH port.
LINUX_REF_VM := env $(GUIX_VM_ENV) GUIX_OS="$(abspath guix/linux-reference.scm)" \
	GUIX_GUEST_KIND=linux GUIX_IMAGE_TYPE=qcow2 \
	GUIX_IMAGE_BASENAME=linux-reference GUIX_IMAGE_OPTS="--image-size=8G" \
	GUIX_DIR="$(abspath $(IMG_DIR)/guix-linux)" GUIX_SSH_PORT=2224 \
	GUIX_MEMORY=4096 GUIX_CPUS=4 GUIX_ROOT_PARTITION=2 \
	bash scripts/guix_vm.sh

linux-ref-image:
	@$(LINUX_REF_VM) image
linux-ref-start:
	@$(LINUX_REF_VM) start -- $(GUIX_QEMU_ARGS)
linux-ref-stop:
	@$(LINUX_REF_VM) stop
linux-ref-status:
	@$(LINUX_REF_VM) status
linux-ref-ssh:
	@$(LINUX_REF_VM) ssh root $(if $(GUIX_SSH_COMMAND),"$(GUIX_SSH_COMMAND)")
linux-ref-ssh-peon:
	@$(LINUX_REF_VM) ssh peon $(if $(GUIX_SSH_COMMAND),"$(GUIX_SSH_COMMAND)")
linux-ref-screenshot:
	@$(LINUX_REF_VM) screenshot
linux-ref-qmp:
	@$(LINUX_REF_VM) qmp $(GUIX_QMP_ARGS)

# The live graphics gate of the niri plan's stage 0 (Hurd and Linux
# reference guests, both host GPUs; STAGE0_GPUS=nvidia for one).
stage0-check:
	@bash scripts/stage0_check.sh

# The niri platform guest (guix/hurd64-platform.scm) and its tests.
stage1-check:
	@bash scripts/stage1_check.sh
