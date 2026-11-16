#!/usr/bin/env bash
# Graphics, tracing and control options shared by the Hurd and Linux guests.
# Source this file, then call guix_qemu_options. The resulting Bash arrays are
# GUIX_QEMU_OPTIONS and GUIX_QEMU_DISPLAY_OPTIONS.

guix_qemu_options_die() {
    echo "guix_vm: $*" >&2
    return 1
}

guix_qemu_render_node() {
    local gpu="${1:-${GPU:-}}" driver node device
    case "$gpu" in
        amd) driver=amdgpu ;;
        nvidia) driver=nvidia ;;
        *) guix_qemu_options_die "GPU must be amd or nvidia for egl-headless (got '$gpu')" ; return 1 ;;
    esac
    local sysfs="${GPU_SYSFS_DIR:-/sys/class/drm}"
    for device in "$sysfs"/renderD*; do
        [[ -e "$device/device/driver" ]] || continue
        if [[ "$(basename "$(readlink -f "$device/device/driver")")" == "$driver" ]]; then
            node="/dev/dri/$(basename "$device")"
            [[ -r "$node" ]] || guix_qemu_options_die "$node is not readable"
            printf '%s\n' "$node"
            return 0
        fi
    done
    guix_qemu_options_die "no render node with driver $driver was found"
}

guix_qemu_host_vk_device() {
    local gpu="$1" driver device vendor pci_device
    case "$gpu" in
        amd) driver=amdgpu ;;
        nvidia) driver=nvidia ;;
        *) return 1 ;;
    esac
    for device in "${GPU_SYSFS_DIR:-/sys/class/drm}"/renderD*/device; do
        [[ -e "$device/driver" ]] || continue
        [[ "$(basename "$(readlink -f "$device/driver")")" == "$driver" ]] || continue
        vendor="$(< "$device/vendor")"
        pci_device="$(< "$device/device")"
        printf '%s:%s\n' "${vendor#0x}" "${pci_device#0x}"
        return 0
    done
    return 1
}

guix_qemu_options() {
    local gpu="${GUIX_GPU:-none}" display="${GUIX_DISPLAY:-none}"
    local qmp_socket="${QMP_SOCKET:-${XDG_RUNTIME_DIR:-/tmp}/hurdkit-guix-${GUIX_SSH_PORT:-2223}.qmp}"
    GUIX_QEMU_OPTIONS=()
    GUIX_QEMU_DISPLAY_OPTIONS=()
    local device_options=",id=gpu0"
    local selected_gpu="${GPU:-}"
    if [[ "$gpu" == venus && -n "$selected_gpu" && -z "${GPU_VK_DEVICE:-}" ]]; then
        GPU_VK_DEVICE="$(guix_qemu_host_vk_device "$selected_gpu")" || {
            guix_qemu_options_die "no Vulkan PCI ID found for GPU=$selected_gpu"
            return 1
        }
    fi
    if [[ -n "${GPU_VK_DEVICE:-}" ]]; then
        [[ "$gpu" == venus ]] || {
            guix_qemu_options_die "GPU_VK_DEVICE requires GUIX_GPU=venus"
            return 1
        }
        [[ "$GPU_VK_DEVICE" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{4}$ ]] || {
            guix_qemu_options_die "GPU_VK_DEVICE must be a PCI vendor:device pair"
            return 1
        }
        export MESA_VK_DEVICE_SELECT="$GPU_VK_DEVICE"
        local icd_name icd_file
        case "$selected_gpu" in
            amd) icd_name=radeon_icd.x86_64.json ;;
            nvidia) icd_name=nvidia_icd.json ;;
            *) icd_name= ;;
        esac
        icd_file="${GPU_VK_ICD_FILE:-${VK_DRIVER_DIR:-/run/opengl-driver/share/vulkan/icd.d}/$icd_name}"
        if [[ -n "$icd_name" && -f "$icd_file" ]]; then
            export VK_DRIVER_FILES="$icd_file"
            echo "guix_vm: Venus host ICD $VK_DRIVER_FILES" >&2
        elif [[ "$gpu" == venus ]]; then
            guix_qemu_options_die "no host Vulkan ICD for GPU=$selected_gpu at $icd_file"
            return 1
        fi
    fi
    case "$gpu" in
        none) device_options= ;;
        2d) GUIX_QEMU_OPTIONS+=(-device "virtio-vga${device_options}") ;;
        virgl) GUIX_QEMU_OPTIONS+=(-device "virtio-vga-gl${device_options}") ;;
        venus) GUIX_QEMU_OPTIONS+=(-device "virtio-vga-gl,blob=true,hostmem=4G,venus=true${device_options}") ;;
        nctx) GUIX_QEMU_OPTIONS+=(-device "virtio-vga-gl,blob=true,hostmem=4G,drm_native_context=on${device_options}") ;;
        *) guix_qemu_options_die "unknown GUIX_GPU '$gpu' (use none, 2d, virgl, venus or nctx)" ; return 1 ;;
    esac
    case "$display" in
        none) GUIX_QEMU_DISPLAY_OPTIONS=(-display none) ;;
        gtk) GUIX_QEMU_DISPLAY_OPTIONS=(-display 'gtk,gl=on') ;;
        egl-headless)
            local node
            node="$(guix_qemu_render_node)" || return 1
            [[ -n "$node" ]] || return 1
            if [[ "$gpu" == none || "$gpu" == 2d ]]; then
                GUIX_QEMU_DISPLAY_OPTIONS=(-display "egl-headless,rendernode=$node")
            else
                GUIX_QEMU_DISPLAY_OPTIONS=(-display "egl-headless,rendernode=$node,gl=on")
            fi
            ;;
        *) guix_qemu_options_die "unknown GUIX_DISPLAY '$display' (use none, egl-headless or gtk)" ; return 1 ;;
    esac
    GUIX_QEMU_OPTIONS+=(-smp "${GUIX_CPUS:-4}" -qmp "unix:$qmp_socket,server=on,wait=off")
    if [[ -n "${GUIX_TRACE:-}" ]]; then
        local trace_file="${GUIX_TRACE_FILE:-$GUIX_DIR/virtio-gpu.trace}"
        GUIX_QEMU_OPTIONS+=(-trace "${GUIX_TRACE},file=$trace_file")
    fi
    if [[ "${GUIX_VENUS_MEMFD:-0}" == 1 ]]; then
        [[ "$gpu" == venus ]] || { guix_qemu_options_die "GUIX_VENUS_MEMFD=1 requires GUIX_GPU=venus"; return 1; }
        GUIX_QEMU_OPTIONS+=(-object "memory-backend-memfd,id=mem,size=${GUIX_MEMORY}M,share=on" -machine memory-backend=mem)
    fi
}
