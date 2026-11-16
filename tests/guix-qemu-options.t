#!/usr/bin/env bash
# TAP tests for stage 0's graphics and tracing option construction.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPTIONS="$REPO_ROOT/scripts/guix_qemu_options.sh"
echo '1..28'
failures=0
number=0
declare -a RESULT=()
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
# A fake host with an NVIDIA render node (renderD128) and an AMD one
# (renderD129), as sysfs and /dev/dri show them, and a Vulkan ICD for each.
FAKE_HOST="$(mktemp -d)"
trap 'rm -rf "$FAKE_HOST"' EXIT
# Keep the sockets of a guest that may be running out of reach.
export XDG_RUNTIME_DIR="$FAKE_HOST/run"
mkdir -p "$XDG_RUNTIME_DIR"
make_render_node() {
    local node="$1" driver="$2" vendor="$3" device="$4"
    mkdir -p "$FAKE_HOST/drivers/$driver" "$FAKE_HOST/devices/$node" \
        "$FAKE_HOST/sys/$node" "$FAKE_HOST/dri" "$FAKE_HOST/icd"
    ln -s "$FAKE_HOST/drivers/$driver" "$FAKE_HOST/devices/$node/driver"
    printf '%s\n' "$vendor" > "$FAKE_HOST/devices/$node/vendor"
    printf '%s\n' "$device" > "$FAKE_HOST/devices/$node/device"
    ln -s "$FAKE_HOST/devices/$node" "$FAKE_HOST/sys/$node/device"
    : > "$FAKE_HOST/dri/$node"
}
make_render_node renderD128 nvidia 0x10de 0x249c
make_render_node renderD129 amdgpu 0x1002 0x1638
: > "$FAKE_HOST/icd/radeon_icd.x86_64.json"
: > "$FAKE_HOST/icd/nvidia_icd.json"
export GUIX_DRM_SYSFS="$FAKE_HOST/sys" GUIX_DRI_DIR="$FAKE_HOST/dri" \
    GUIX_VK_DRIVER_DIR="$FAKE_HOST/icd"
options() {
    env -u GUIX_GPU -u GUIX_DISPLAY -u GUIX_HOST_GPU -u GUIX_TRACE \
        -u GUIX_CPUS -u QMP_SOCKET "$@" bash -c 'source "$1"; guix_qemu_options; printf "%s\n" "${GUIX_QEMU_OPTIONS[@]}" "${GUIX_QEMU_DISPLAY_OPTIONS[@]}"' _ "$OPTIONS"
}
# lacks PATTERN: no option word matches the shell pattern.
lacks() {
    local word
    for word in "${RESULT[@]}"; do
        [[ "$word" == $1 ]] && return 1
    done
    return 0
}
has_pair() {
    local flag="$1" value="$2" index
    for (( index = 0; index + 1 < ${#RESULT[@]}; index++ )); do
        [[ "${RESULT[index]}" == "$flag" && "${RESULT[index + 1]}" == "$value" ]] && return 0
    done
    return 1
}

mapfile -t RESULT < <(options GUIX_GPU=none)
check 'none preserves the Hurd default with no added GPU' lacks '*virtio-vga*'
mapfile -t RESULT < <(options GUIX_GPU=2d)
check '2d selects the 2D virtio VGA device' has_pair -device virtio-vga,id=gpu0
mapfile -t RESULT < <(options GUIX_GPU=virgl)
check 'virgl enables GL without blobs' has_pair -device virtio-vga-gl,id=gpu0
check 'virtio display has a stable QMP console device id' has_pair -device virtio-vga-gl,id=gpu0
check 'none is the compatible default display' has_pair -display none
mapfile -t RESULT < <(options GUIX_GPU=venus)
check 'Venus enables the required capset' has_pair -device virtio-vga-gl,blob=true,hostmem=4G,venus=true,id=gpu0
mapfile -t RESULT < <(options GUIX_GPU=nctx)
check 'native context enables blob and DRM context support' has_pair -device virtio-vga-gl,blob=true,hostmem=4G,drm_native_context=on,id=gpu0
mapfile -t RESULT < <(options GUIX_GPU=2d GUIX_DISPLAY=none)
check 'none display remains supported' has_pair -display none
mapfile -t RESULT < <(options GUIX_GPU=2d GUIX_DISPLAY=egl-headless GUIX_HOST_GPU=amd)
check 'egl-headless selects AMD by driver name' has_pair -display egl-headless,rendernode=$FAKE_HOST/dri/renderD129
mapfile -t RESULT < <(options GUIX_GPU=2d GUIX_DISPLAY=egl-headless GUIX_HOST_GPU=nvidia)
check 'egl-headless selects NVIDIA by driver name' has_pair -display egl-headless,rendernode=$FAKE_HOST/dri/renderD128
mapfile -t RESULT < <(options GUIX_GPU=2d GUIX_DISPLAY=gtk)
check 'gtk is interactive and GL enabled' has_pair -display gtk,gl=on
mapfile -t RESULT < <(options GUIX_GPU=2d GUIX_TRACE='virtio_gpu_cmd_*' GUIX_DIR=/tmp/reference)
check 'trace patterns select the default trace file' has_pair -trace 'virtio_gpu_cmd_*,file=/tmp/reference/virtio-gpu.trace'
mapfile -t RESULT < <(options GUIX_GPU=2d GUIX_TRACE='virtio_gpu_cmd_*' GUIX_TRACE_FILE=/tmp/a.trace)
check 'explicit trace files are preserved' has_pair -trace 'virtio_gpu_cmd_*,file=/tmp/a.trace'
mapfile -t RESULT < <(options GUIX_GPU=virgl GUIX_DISPLAY=egl-headless GUIX_HOST_GPU=amd)
check 'accelerated headless display explicitly enables OpenGL' has_pair -display egl-headless,rendernode=$FAKE_HOST/dri/renderD129,gl=on
mapfile -t RESULT < <(options GUIX_GPU=2d GUIX_TRACE='virtio_gpu_cmd_*' GUIX_TRACE_FILE=/tmp/a.trace)
check 'a QMP socket is created beside the monitor socket' has_pair -qmp "unix:${XDG_RUNTIME_DIR:-/tmp}/hurdkit-guix-2223.qmp,server=on,wait=off"
check 'the CPU count is the QEMU default unless asked for' lacks -smp
mapfile -t RESULT < <(options GUIX_GPU=none GUIX_CPUS=4)
check 'GUIX_CPUS sets the number of virtual CPUs' has_pair -smp 4
check 'source-only helper has no command-line side effects' bash -c "test -z \"\$(bash '$OPTIONS')\""
check 'invalid GPU mode is rejected' bash -c "source '$OPTIONS'; GUIX_GPU=bogus; ! guix_qemu_options >/dev/null 2>&1"
check 'invalid display is rejected' bash -c "source '$OPTIONS'; GUIX_GPU=2d GUIX_DISPLAY=bogus; ! guix_qemu_options >/dev/null 2>&1"
check 'invalid GPU selector is rejected' bash -c "source '$OPTIONS'; GUIX_GPU=2d GUIX_DISPLAY=egl-headless GUIX_HOST_GPU=bogus; ! guix_qemu_options >/dev/null 2>&1"
start_forwards_display() {
    local dir="$1"
    mkdir "$dir/bin" "$dir/guest" "$dir/keys"
    cat > "$dir/bin/qemu-system-x86_64" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_DIR/qemu.args"
SH
    cat > "$dir/bin/qemu-img" <<'SH'
#!/usr/bin/env bash
set -e
if [[ "$1" == create ]]; then
    eval 'overlay=${!#}'
    : > "$overlay"
fi
SH
    printf '#!/usr/bin/env bash\nexit 1\n' > "$dir/bin/ssh"
    chmod +x "$dir/bin/"*
    touch "$dir/guest/hurd64.base.qcow2"
    TEST_DIR="$dir" PATH="$dir/bin:$PATH" GUIX_DIR="$dir/guest" \
        GUIX_BOOT_ATTEMPTS=1 GUIX_BOOT_TIMEOUT=1 \
        GUIX_GPU=virgl GUIX_DISPLAY=egl-headless GUIX_HOST_GPU=amd \
        bash "$REPO_ROOT/scripts/guix_vm.sh" start -- >/dev/null 2>&1 || true
    [[ -f "$dir/qemu.args" ]] || return 1
    grep -F -x -A1 -- '-display' "$dir/qemu.args" | tail -n 1 |
        grep -Fxq "egl-headless,rendernode=$FAKE_HOST/dri/renderD129,gl=on" &&
    grep -F -x -A1 -- '-monitor' "$dir/qemu.args" | tail -n 1 |
        grep -Eq '^unix:.*,server=on,wait=off$'
}
test_dir="$(mktemp -d)"
check 'start forwards the selected display into the real QEMU command' start_forwards_display "$test_dir"
rm -rf "$test_dir"
check 'managed QEMU options cannot be overridden' bash -c 'dir=$(mktemp -d); trap "rm -rf \"$dir\"" EXIT; touch "$dir/hurd64.base.qcow2"; if GUIX_DIR="$dir" QEMU_SYSTEM=true QEMU_IMG=true bash "$1/scripts/guix_vm.sh" start -- -qmp fake >/dev/null 2>&1; then exit 1; else exit 0; fi' _ "$REPO_ROOT"
check 'default Hurd boot has no extra memory object' bash -c "source '$OPTIONS'; GUIX_GPU=none; guix_qemu_options; ! printf '%s\n' \"\${GUIX_QEMU_OPTIONS[@]}\" | grep -q memory-backend"
check 'Venus memfd is available for the explicit experiment' bash -c "source '$OPTIONS'; GUIX_GPU=venus GUIX_MEMORY=4096 GUIX_VENUS_MEMFD=1; guix_qemu_options; printf '%s\n' \"\${GUIX_QEMU_OPTIONS[@]}\" | grep -Fq 'memory-backend-memfd,id=mem,size=4096M,share=on'"
venus_selects_host_gpu() {
    local dir="$1"
    mkdir "$dir/bin" "$dir/guest"
    cat > "$dir/bin/qemu-system-x86_64" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_DIR/qemu.args"
printf 'MESA_VK_DEVICE_SELECT=%s\n' "${MESA_VK_DEVICE_SELECT:-}" > "$TEST_DIR/qemu.env"
SH
    cp "$dir/bin/qemu-system-x86_64" "$dir/bin/qemu-img"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$dir/bin/ssh"
    chmod +x "$dir/bin/"*
    touch "$dir/guest/hurd64.base.qcow2"
    TEST_DIR="$dir" PATH="$dir/bin:$PATH" GUIX_DIR="$dir/guest" \
        GUIX_BOOT_ATTEMPTS=1 GUIX_BOOT_TIMEOUT=1 \
        GUIX_GPU=venus GUIX_DISPLAY=egl-headless GUIX_HOST_GPU=amd \
        bash "$REPO_ROOT/scripts/guix_vm.sh" start -- >/dev/null 2>&1 || true
    grep -Fxq 'MESA_VK_DEVICE_SELECT=1002:1638' "$dir/qemu.env"
}
test_dir="$(mktemp -d)"
check 'Venus selects the host GPU through its Vulkan device-select layer' venus_selects_host_gpu "$test_dir"
rm -rf "$test_dir"
check 'explicit Vulkan device selector is validated' bash -c "source '$OPTIONS'; GUIX_GPU=venus GUIX_HOST_GPU=amd GUIX_VK_DEVICE=bogus; ! guix_qemu_options >/dev/null 2>&1"
exit "$failures"
