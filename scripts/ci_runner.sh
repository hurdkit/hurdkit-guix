#!/usr/bin/env bash
# Prepare a GitHub-hosted Ubuntu runner for building the released images
# and the test guests (.github/workflows/images.yml and guests.yml): disk,
# KVM, Nix, a goonix guix-daemon, and the store caches. Most commands need
# root and run their privileged parts through SUDO. See skills/GUIX.md,
# "Release images" and "Guest tests in CI".
#
# Usage: ci_runner.sh <command> [arguments]
#
#   disk               pick an ext4 filesystem with CI_DISK_GB free and put
#                      /gnu, /var/guix, the daemon's build directory, the
#                      saved store (CI_STORE_CACHE) and the images
#                      (CI_WORK/release) on it
#   kvm [--require]    let the runner's user open /dev/kvm; with --require,
#                      fail when it cannot (the guest tests need KVM)
#   install-nix        install Nix (NIX_VERSION, checked against
#                      NIX_INSTALL_SHA256) as a multi-user daemon
#   nix-cache-export DIR
#                      copy the store paths of the development shell that
#                      cache.nixos.org lacks (goonix) into the binary cache DIR
#   guix-users         create the build users of the Guix daemon
#   guix-daemon        start goonix's guix-daemon (run it inside nix develop)
#                      with the build farms' keys authorized and no signing key
#   guix-stop          stop that daemon
#   guix-journal       print what that daemon logged, and the kernel's lines
#                      about processes it killed or that crashed (after a
#                      failed check; never fails itself)
#   store-save FILE    write /gnu/store and the store database to FILE (daemon
#                      stopped)
#   store-restore FILE unpack FILE into /gnu/store and /var/guix (daemon
#                      stopped)
#   store-fingerprint  print a checksum of the list of store items
#   no-signing-key     fail if the machine has an archive signing key
#
# Outside a runner, CI_ROOT puts every system path under a directory and
# SUDO can be empty; the tests do that.

set -euo pipefail

CI_ROOT="${CI_ROOT:-}"
SUDO="${SUDO-sudo}"
# Free space that a cold build needs, in GiB.
CI_DISK_GB="${CI_DISK_GB:-30}"
# The disk that GitHub's runners mount as a second, almost empty disk.
CI_ALT_DISK="${CI_ALT_DISK:-$CI_ROOT/mnt}"
# Directories of the runner image that a build does not need, removed when
# the root filesystem has to make room.
CI_REMOVABLE="${CI_REMOVABLE:-/usr/share/dotnet /usr/local/lib/android /opt/ghc /usr/local/.ghcup /opt/hostedtoolcache/CodeQL /usr/local/share/boost /usr/share/swift /opt/microsoft /usr/local/share/powershell}"
NIX_VERSION="${NIX_VERSION:-2.35.4}"
NIX_INSTALL_SHA256="${NIX_INSTALL_SHA256:-118c3dfa04bdc946b3f577365b9a295607142c9b920e2c07b184e266d62b1ee1}"
# The binary cache that holds goonix between runs (actions/cache).
CI_NIX_CACHE="${CI_NIX_CACHE:-$HOME/.cache/hurdkit-ci/nix}"
# Where the saved Guix store is, at a fixed path for actions/cache; disk
# mounts the working disk's cache directory there.
CI_STORE_CACHE="${CI_STORE_CACHE:-$HOME/.cache/hurdkit-ci/store}"
GUIX_BUILD_GROUP="${GUIX_BUILD_GROUP:-guixbuild}"
GUIX_BUILD_USERS="${GUIX_BUILD_USERS:-8}"
GUIX_SUBSTITUTE_URLS="${GUIX_SUBSTITUTE_URLS:-https://bordeaux.guix.gnu.org https://ci.guix.gnu.org}"
GUIX_MAX_JOBS="${GUIX_MAX_JOBS:-2}"
GUIX_UNIT="${GUIX_UNIT:-hurdkit-guix-daemon}"

die() {
    echo "ci_runner: $*" >&2
    exit 1
}

say() {
    echo "ci_runner: $*" >&2
}

# run CMD...: run a privileged command.
run() {
    if [[ -n "$SUDO" ]]; then
        $SUDO "$@"
    else
        "$@"
    fi
}

# Set a variable for the later steps of the job (or print it outside one).
export_var() {
    if [[ -n "${GITHUB_ENV:-}" ]]; then
        echo "$1=$2" >> "$GITHUB_ENV"
    else
        echo "$1=$2"
    fi
}

fs_type() {
    findmnt -no FSTYPE -T "$1"
}

# Free space of the filesystem of $1 in GiB.
free_gb() {
    df -P -BG "$1" | awk 'NR == 2 { sub(/G$/, "", $4); print $4 }'
}

cmd_disk() {
    local work=""
    if mountpoint -q "$CI_ALT_DISK" 2>/dev/null &&
            [[ "$(fs_type "$CI_ALT_DISK")" == ext4 ]] &&
            (( $(free_gb "$CI_ALT_DISK") >= CI_DISK_GB )); then
        work="$CI_ALT_DISK/hurdkit-ci"
    else
        say "no second disk with ${CI_DISK_GB} GiB; making room on /"
        local dir
        for dir in $CI_REMOVABLE; do
            run rm -rf "$CI_ROOT$dir"
        done
        (( $(free_gb "$CI_ROOT/") >= CI_DISK_GB )) ||
            die "only $(free_gb "$CI_ROOT/") GiB free on /, need $CI_DISK_GB (CI_DISK_GB)"
        work="$CI_ROOT/var/lib/hurdkit-ci"
    fi
    run mkdir -p "$work/gnu" "$work/var-guix" "$work/build" "$work/cache" \
        "$work/release" "$CI_ROOT/gnu" "$CI_ROOT/var/guix"
    run chmod 755 "$work/build"
    # The daemon writes the translators of the Hurd image as gnu.*
    # extended attributes, which Linux accepts on ext4 only (G4).
    [[ "$(fs_type "$work/build")" == ext4 ]] ||
        die "$work/build is on $(fs_type "$work/build"), not ext4 (G4)"
    run mount --bind "$work/gnu" "$CI_ROOT/gnu"
    run mount --bind "$work/var-guix" "$CI_ROOT/var/guix"
    # $work is root's. The runner's own steps write the saved store to
    # cache and the images to release (images.yml), so those two are its.
    run chown "$(id -u):$(id -g)" "$work/cache" "$work/release"
    mkdir -p "$CI_STORE_CACHE"
    run mount --bind "$work/cache" "$CI_STORE_CACHE"
    say "working on $work ($(free_gb "$work") GiB free, $(fs_type "$work"))"
    export_var CI_WORK "$work"
}

cmd_kvm() {
    local require=0
    case "${1:-}" in
        "") ;;
        --require) require=1 ;;
        *) die "usage: ci_runner.sh kvm [--require]" ;;
    esac
    if [[ ! -e "$CI_ROOT/dev/kvm" ]]; then
        if (( require )); then
            die "no /dev/kvm; the guest tests need KVM"
        fi
        say "no /dev/kvm; guests will run without acceleration"
        return 0
    fi
    # The rule of GitHub's announcement of KVM on hosted Linux runners.
    echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' |
        run tee "$CI_ROOT/etc/udev/rules.d/99-kvm4all.rules" >/dev/null
    run udevadm control --reload-rules
    run udevadm trigger --name-match=kvm
    run udevadm settle
    if [[ -r "$CI_ROOT/dev/kvm" && -w "$CI_ROOT/dev/kvm" ]]; then
        say "/dev/kvm is usable"
    elif (( require )); then
        die "/dev/kvm exists but is not usable; the guest tests need KVM"
    else
        say "/dev/kvm exists but is not usable; guests will run without acceleration"
    fi
}

cmd_install_nix() {
    local dir conf
    dir="$(mktemp -d)"
    curl -fsSL --retry 5 -o "$dir/install" \
        "https://releases.nixos.org/nix/nix-$NIX_VERSION/install"
    echo "$NIX_INSTALL_SHA256  $dir/install" | sha256sum -c --quiet - ||
        die "the Nix $NIX_VERSION installer does not have the pinned checksum"
    mkdir -p "$CI_NIX_CACHE"
    conf="$dir/nix.conf"
    cat > "$conf" <<EOF
experimental-features = nix-command flakes
trusted-users = root $(id -un)
max-jobs = auto
# goonix from the cache of earlier runs, before cache.nixos.org. Its paths
# are not signed; actions/cache of this repository is what vouches for them.
extra-substituters = file://$CI_NIX_CACHE?trusted=1&priority=10
EOF
    # The installer checks the tarball against the checksum it carries.
    sh "$dir/install" --daemon --yes --no-channel-add --nix-extra-conf-file "$conf"
    rm -rf "$dir"
    if [[ -n "${GITHUB_PATH:-}" ]]; then
        echo /nix/var/nix/profiles/default/bin >> "$GITHUB_PATH"
    fi
}

cmd_nix_cache_export() {
    (( $# == 1 )) || die "usage: ci_runner.sh nix-cache-export DIR"
    local dir="$1" work path missing=()
    work="$(mktemp -d)"
    # The shell's environment refers to every package of the shell.
    nix develop --profile "$work/shell" --command true
    while read -r path; do
        if ! nix path-info --store https://cache.nixos.org "$path" >/dev/null 2>&1; then
            missing+=("$path")
        fi
    done < <(nix path-info --recursive "$work/shell")
    printf '%s\n' "${missing[@]}" | grep -q -- '-goonix-' ||
        die "goonix is not among the paths that cache.nixos.org lacks"
    printf 'ci_runner: exporting %s\n' "${missing[@]}" >&2
    # With their closures: a binary cache takes no path whose references
    # it lacks.
    nix copy --to "file://$work/cache?compression=zstd" "${missing[@]}"
    # The Nix daemon may have created files in DIR, as root, while it
    # looked for goonix there.
    run rm -rf "$dir"
    mkdir -p "$(dirname "$dir")"
    mv "$work/cache" "$dir"
    rm -rf "$work"
}

cmd_guix_users() {
    local i name
    getent group "$GUIX_BUILD_GROUP" >/dev/null ||
        run groupadd --system "$GUIX_BUILD_GROUP"
    for (( i = 1; i <= GUIX_BUILD_USERS; i++ )); do
        printf -v name 'guixbuilder%02d' "$i"
        getent passwd "$name" >/dev/null && continue
        run useradd --system --gid "$GUIX_BUILD_GROUP" --groups "$GUIX_BUILD_GROUP" \
            --home-dir /var/empty --no-create-home --shell /usr/sbin/nologin \
            --comment "Guix build user $i" "$name"
    done
}

cmd_no_signing_key() {
    local file
    for file in "$CI_ROOT/etc/guix/signing-key.pub" "$CI_ROOT/etc/guix/signing-key.sec"; do
        [[ ! -e "$file" ]] || die "$file exists; a released image must not depend on a key of the builder"
    done
}

cmd_guix_daemon() {
    local daemon guix share key
    daemon="$(command -v guix-daemon)" || die "no guix-daemon in PATH; run this inside nix develop"
    guix="$(command -v guix)"
    "$guix" --version | sed -n 1p | grep -q goonix || die "$guix is not goonix (G1)"
    [[ -n "${CI_WORK:-}" ]] || die "CI_WORK is not set; run ci_runner.sh disk first"
    cmd_no_signing_key
    [[ "$(fs_type "$CI_WORK/build")" == ext4 ]] || die "$CI_WORK/build is not on ext4 (G4)"
    run mkdir -p "$CI_ROOT/etc/guix" "$CI_ROOT/var/log/guix" "$CI_ROOT/gnu/store"
    # The build farms' keys, as goonix ships them; nothing else is trusted.
    share="$(dirname "$(dirname "$(readlink -f "$guix")")")/share/guix"
    for key in bordeaux.guix.gnu.org ci.guix.gnu.org; do
        [[ -f "$share/$key.pub" ]] || die "goonix lacks $share/$key.pub"
        run "$guix" archive --authorize < "$share/$key.pub"
    done
    run systemd-run --unit="$GUIX_UNIT" --collect \
        --setenv=TMPDIR="$CI_WORK/build" --setenv=LC_ALL=C.UTF-8 \
        "$daemon" --build-users-group="$GUIX_BUILD_GROUP" \
        --max-jobs="$GUIX_MAX_JOBS" --substitute-urls="$GUIX_SUBSTITUTE_URLS"
    local i
    for (( i = 0; i < 30; i++ )); do
        [[ -S "$CI_ROOT/var/guix/daemon-socket/socket" ]] && break
        sleep 1
    done
    [[ -S "$CI_ROOT/var/guix/daemon-socket/socket" ]] || die "the daemon did not open its socket"
    # A client that talks to the daemon.
    local probe
    probe="$(mktemp)"
    echo '(use-modules (guix store)) (with-store store (store-connection-version store))' > "$probe"
    "$guix" repl -- "$probe" || die "the daemon does not answer"
    rm -f "$probe"
    say "guix-daemon runs: $("$guix" --version | sed -n 1p), build directory $CI_WORK/build"
}

cmd_guix_stop() {
    if run systemctl is-active --quiet "$GUIX_UNIT"; then
        run systemctl stop "$GUIX_UNIT"
    fi
}

cmd_guix_journal() {
    # A daemon that dies takes its reason with it: its own log, and the
    # kernel's word when it was killed (out of memory) or crashed.
    run journalctl --unit="$GUIX_UNIT" --no-pager --lines=300 || true
    { run dmesg 2>/dev/null || true; } |
        grep -iE 'out of memory|oom|killed process|segfault|general protection' |
        tail -n 40 || true
}

cmd_store_save() {
    (( $# == 1 )) || die "usage: ci_runner.sh store-save FILE"
    local file="$1"
    run systemctl is-active --quiet "$GUIX_UNIT" 2>/dev/null &&
        die "stop the daemon first (ci_runner.sh guix-stop)"
    mkdir -p "$(dirname "$file")"
    # Only what the database describes, and the database itself; the
    # daemon's other state (GC roots, profiles, the narinfo cache) is
    # rebuilt.
    run tar -C "$CI_ROOT/" --zstd -cf "$file.tmp" gnu/store var/guix/db
    run chown "$(id -u):$(id -g)" "$file.tmp"
    mv -f "$file.tmp" "$file"
    say "saved the store: $(du -h "$file" | cut -f1)"
}

cmd_store_restore() {
    (( $# == 1 )) || die "usage: ci_runner.sh store-restore FILE"
    local file="$1"
    if [[ ! -f "$file" ]]; then
        say "no saved store; starting empty"
        return 0
    fi
    run tar -C "$CI_ROOT/" --zstd -xf "$file"
    rm -f "$file"
    say "restored the store"
}

cmd_store_fingerprint() {
    find "$CI_ROOT/gnu/store" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null |
        sort | sha256sum | cut -d' ' -f1
}

command="${1:-}"
[[ $# -gt 0 ]] && shift
case "$command" in
    disk) cmd_disk "$@" ;;
    kvm) cmd_kvm "$@" ;;
    install-nix) cmd_install_nix "$@" ;;
    nix-cache-export) cmd_nix_cache_export "$@" ;;
    guix-users) cmd_guix_users "$@" ;;
    guix-daemon) cmd_guix_daemon "$@" ;;
    guix-stop) cmd_guix_stop "$@" ;;
    guix-journal) cmd_guix_journal "$@" ;;
    store-save) cmd_store_save "$@" ;;
    store-restore) cmd_store_restore "$@" ;;
    store-fingerprint) cmd_store_fingerprint "$@" ;;
    no-signing-key) cmd_no_signing_key "$@" ;;
    *)
        sed -n '2,/^$/s/^# \{0,1\}//p' "$0" >&2
        exit 2
        ;;
esac
