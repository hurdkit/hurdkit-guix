#!/usr/bin/env bash
# TAP: the stage gates keep a GUIX_OS given from outside (a flake reference)
# and pass it to "guix system image" with the public key options; without one
# they use their own file declaration. Stand-in guix/QEMU/ssh: no build, no
# real guest. The image call is recorded before the gate tries to boot.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/hurdkit-guix-gate-os.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/keys"
printf 'ssh-ed25519 root-test\n' > "$work/keys/root_ed25519.pub"
printf 'ssh-ed25519 peon-test\n' > "$work/keys/peon_ed25519.pub"
printf 'synthetic\n' > "$work/keys/root_ed25519"
printf 'synthetic\n' > "$work/keys/peon_ed25519"
printf 'public host key\n' > "$work/host.pub"
printf 'synthetic image\n' > "$work/store-image"

# A binary P6 writer in Tcl: 640x480, background 0a0f1a, with the triangle
# regions frames_valid checks when MODE is "triangle".
cat > "$work/ppm.tcl" <<'TCL'
lassign $argv path mode
set w 640; set h 480
set bg [binary format ccc 10 15 26]
set pixels [string repeat $bg [expr {$w*$h}]]
proc put {x y r g b} {
    upvar pixels pixels w w
    set o [expr {($y*$w+$x)*3}]
    set pixels [string replace $pixels $o [expr {$o+2}] [binary format ccc $r $g $b]]
}
if {$mode eq "triangle" || [string match {egl-*} $mode]} {
    put 192 85 164 57 31
    put 448 85 57 164 31
    put 320 390 32 32 188
}
if {[string match {shm-*} $mode]} {
    # Alternate the top and bottom halves by frame parity so kept frames
    # differ over well more than 20% of the pixels.
    set n [string range $mode 4 end]
    set half [expr {$n % 2}]
    set y0 [expr {$half * ($h/2)}]
    set fill [binary format ccc 200 120 40]
    set row [string repeat $fill $w]
    for {set y $y0} {$y < $y0 + $h/2} {incr y} {
        set o [expr {$y*$w*3}]
        set pixels [string replace $pixels $o [expr {$o+$w*3-1}] $row]
    }
}
set f [open $path wb]
puts -nonewline $f "P6\n$w $h\n255\n$pixels"
close $f
TCL
export GUIX_TEST_PPM="$work/ppm.tcl"

cat > "$work/bin/guix" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    --version) echo 'guix (GNU Guix) goonix'; exit 0 ;;
    flake) exit 0 ;;
    system)
        printf '%s\n' "$@" > "$GUIX_TEST_CALLS"
        printf '%s\n' "$GUIX_TEST_IMAGE"
        exit 0 ;;
    build)
        # Fake store paths so the gate scripts proceed past their builds.
        # stage2 needs a graphics-tests tree with a smoke.sh that succeeds.
        if [[ "$*" == *hurdkit-graphics-tests* ]]; then
            mkdir -p "$GUIX_TEST_STORE/graphics/bin"
            # ppm-test writes renderer.txt and a triangle.ppm with the regions
            # frames_valid checks; smoke.sh writes the kept frames at 640x480.
            # PPMs are written with tclsh (binary P6), no other tooling.
            cat > "$GUIX_TEST_STORE/graphics/bin/ppm-test" <<'PPM'
#!/usr/bin/env bash
out="$1"
printf 'softpipe\n' > "$out/renderer.txt"
tclsh "$GUIX_TEST_PPM" "$out/triangle.ppm" triangle
PPM
            cat > "$GUIX_TEST_STORE/graphics/bin/smoke.sh" <<'SMOKE'
#!/usr/bin/env bash
for kind in shm egl; do
  mkdir -p "$OUT/$kind"
  for n in 1 $(( (FRAMES + 1) / 2 )) "$FRAMES"; do
    tclsh "$GUIX_TEST_PPM" "$OUT/$kind/wl-$kind-client-frame-$n.ppm" "$kind-$n"
  done
done
SMOKE
            chmod +x "$GUIX_TEST_STORE/graphics/bin/ppm-test" "$GUIX_TEST_STORE/graphics/bin/smoke.sh"
            printf '%s\n' "$GUIX_TEST_STORE/graphics"
        else
            printf '%s\n' "$GUIX_TEST_STORE/virtio" "$GUIX_TEST_STORE/9pfs"
        fi
        exit 0 ;;
esac
exit 0
SH
cat > "$work/bin/qemu-img" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == convert ]]; then cp "$6" "$7"; exit 0; fi
if [[ "${1:-}" == create ]]; then : > "${!#}"; exit 0; fi
exit 0
SH
cat > "$work/bin/flock" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$work/bin/qemu-system-x86_64" <<'SH'
#!/usr/bin/env bash
# Write a live pidfile so guix_vm sees a running guest, then idle briefly.
pidfile=
while (( $# )); do case "$1" in -pidfile) pidfile="$2"; shift 2 ;; *) shift ;; esac; done
setsid sleep 30 < /dev/null > /dev/null 2>&1 &
echo "$!" > "$pidfile"
echo "$!" >> "$GUIX_TEST_PIDS"
SH
cat > "$work/bin/ssh" <<'SH'
#!/usr/bin/env bash
exit 255
SH
chmod +x "$work/bin/"*
mkdir -p "$work/store/virtio/bin" "$work/store/9pfs/bin" "$work/matrices"
export GUIX_TEST_CALLS="$work/calls" GUIX_TEST_IMAGE="$work/store-image"
export GUIX_TEST_STORE="$work/store" GUIX_TEST_PIDS="$work/pids"
export GUIX="$work/bin/guix" QEMU_IMG="$work/bin/qemu-img"
export QEMU_SYSTEM="$work/bin/qemu-system-x86_64"
export SSH_KEY_DIR="$work/keys" GUIX_HOST_SIGNING_KEY="$work/host.pub"
export GUIX_BOOT_TIMEOUT=1 GUIX_BOOT_ATTEMPTS=1
export PATH="$work/bin:$PATH"
: > "$work/pids"
cleanup_pids() { [[ -f "$work/pids" ]] && while read -r p; do kill "$p" 2>/dev/null || true; done < "$work/pids"; }
trap 'cleanup_pids; rm -rf "$work"' EXIT

number=0
failures=0
check() {
    local description="$1"; shift
    number=$((number + 1))
    if "$@"; then echo "ok $number - $description"; else echo "not ok $number - $description"; failures=$((failures + 1)); fi
}

# run_gate SCRIPT GUIX_OS_VALUE OUTDIR: run a gate script far enough to record
# its "guix system image" call, then stop the fake guest it starts.
run_gate() {
    local script="$1" os="$2" dir="$3"
    rm -f "$work/calls"
    mkdir -p "$dir"
    GUIX_DIR="$dir" GUIX_OS="$os" VIRTIO_MATRICES="$work/matrices" \
        bash "$REPO_ROOT/scripts/$script" ${4:-} > "$dir/out" 2>&1
    cleanup_pids
    : > "$work/pids"
}

for spec in "stage1_check.sh:hurd64-platform:2226" "stage2_check.sh:hurd64-wayland:2227"; do
    script="${spec%%:*}"; rest="${spec#*:}"; name="${rest%%:*}"; port="${rest##*:}"
    dir="$work/$name"
    run_gate "$script" "$REPO_ROOT#$name" "$dir"
    check "$script passes an outside flake reference with key options" \
        bash -c 'test "$(tail -n 1 "$1")" = "$2#$3" &&
            grep -Fxq -- "--option=root-public-key=$(cat "$4/keys/root_ed25519.pub")" "$1" &&
            grep -Fxq -- "--option=peon-public-key=$(cat "$4/keys/peon_ed25519.pub")" "$1" &&
            grep -Fxq -- "--option=host-signing-key=$(cat "$4/host.pub")" "$1"' \
        _ "$work/calls" "$REPO_ROOT" "$name" "$work"
    run_gate "$script" "" "$dir"
    check "$script defaults to its own file declaration" \
        bash -c 'test "$(tail -n 1 "$1")" = "$2/guix/$3.scm" &&
            ! grep -q -- "^--option=" "$1"' \
        _ "$work/calls" "$REPO_ROOT" "$name"
done

# virtio: device argument 9p; fake build returns paths, matrix dir is empty so
# the script stops after the image call is recorded.
dir="$work/drivers"
run_gate "guix_virtio_test.sh" "$REPO_ROOT#hurd64-drivers" "$dir" "9p"
check 'guix_virtio_test.sh passes an outside flake reference with key options' \
    bash -c 'test "$(tail -n 1 "$1")" = "$2#hurd64-drivers" &&
        grep -Fxq -- "--option=root-public-key=$(cat "$3/keys/root_ed25519.pub")" "$1" &&
        grep -Fxq -- "--option=peon-public-key=$(cat "$3/keys/peon_ed25519.pub")" "$1"' \
    _ "$work/calls" "$REPO_ROOT" "$work"
run_gate "guix_virtio_test.sh" "" "$dir" "9p"
check 'guix_virtio_test.sh defaults to its own file declaration' \
    bash -c 'test "$(tail -n 1 "$1")" = "$2/guix/hurd64-drivers.scm" &&
        ! grep -q -- "^--option=" "$1"' \
    _ "$work/calls" "$REPO_ROOT"

echo "1..$number"
exit "$failures"
