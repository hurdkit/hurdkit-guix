#!/usr/bin/env bash
# TAP: scripts/ci_runner.sh with its system paths under a temporary
# directory (CI_ROOT), without sudo, and with synthetic mount, df, findmnt,
# systemd and Guix commands. Nothing is mounted, installed or started.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export TEST_DIR

number=0
failures=0
ok() { number=$((number + 1)); echo "ok $number - $*"; }
not_ok() {
    number=$((number + 1))
    echo "not ok $number - $1"
    [[ -z "${2:-}" ]] || while IFS= read -r line; do echo "# $line"; done <<<"$2"
    failures=$((failures + 1))
}

bin="$TEST_DIR/bin"
mkdir -p "$bin"
stub() {
    cat > "$bin/$1"
    chmod +x "$bin/$1"
}
stub mountpoint <<'SH'
#!/usr/bin/env bash
exit "${FAKE_MNT_MOUNTED:-1}"
SH
stub findmnt <<'SH'
#!/usr/bin/env bash
echo "${FAKE_FSTYPE:-ext4}"
SH
stub df <<'SH'
#!/usr/bin/env bash
echo "Filesystem 1G-blocks Used Available Capacity Mounted on"
case "${!#}" in
    */mnt|*/mnt/*) echo "/dev/sdb1 75G 1G ${FAKE_MNT_FREE:-70}G 2% /mnt" ;;
    *) echo "/dev/root 72G 50G ${FAKE_ROOT_FREE:-20}G 70% /" ;;
esac
SH
stub mount <<'SH'
#!/usr/bin/env bash
echo "mount $*" >> "$TEST_DIR/calls"
SH
for command in udevadm groupadd useradd; do
    stub "$command" <<'SH'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "$TEST_DIR/calls"
SH
done
stub getent <<'SH'
#!/usr/bin/env bash
exit 2
SH
stub systemctl <<'SH'
#!/usr/bin/env bash
echo "systemctl $*" >> "$TEST_DIR/calls"
[[ "$1" == is-active ]] && exit "${FAKE_DAEMON_ACTIVE:-3}"
exit 0
SH
stub systemd-run <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_DIR/systemd-run.args"
mkdir -p "$CI_ROOT/var/guix/daemon-socket"
python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' \
    "$CI_ROOT/var/guix/daemon-socket/socket"
SH
stub curl <<'SH'
#!/usr/bin/env bash
while (( $# )); do [[ "$1" == -o ]] && { echo 'not the installer' > "$2"; shift; }; shift; done
SH
mkdir -p "$TEST_DIR/goonix/bin" "$TEST_DIR/goonix/share/guix"
for key in bordeaux.guix.gnu.org ci.guix.gnu.org; do
    echo "(public-key $key)" > "$TEST_DIR/goonix/share/guix/$key.pub"
done
cat > "$TEST_DIR/goonix/bin/guix" <<'SH'
#!/usr/bin/env bash
echo "guix $*" >> "$TEST_DIR/calls"
case "$1" in
    --version) echo "guix (GNU Guix) 1.5.0-goonix.630ee30" ;;
    archive) [[ "$2" == --authorize ]] && echo "authorize $(cat)" >> "$TEST_DIR/calls" ;;
esac
exit 0
SH
printf '#!/bin/sh\nexit 0\n' > "$TEST_DIR/goonix/bin/guix-daemon"
chmod +x "$TEST_DIR/goonix/bin/"*

# runner [VAR=VALUE...] COMMAND...: ci_runner.sh in a fresh CI_ROOT.
root="$TEST_DIR/root"
runner() {
    env PATH="$bin:$TEST_DIR/goonix/bin:$PATH" CI_ROOT="$root" SUDO= \
        HOME="$TEST_DIR/home" GITHUB_ENV= GITHUB_PATH= "$@"
}
fresh_root() {
    rm -rf "${root:?}" "${TEST_DIR:?}/calls" "${TEST_DIR:?}/home"
    mkdir -p "$root/mnt" "$root/usr/share/dotnet" "$root/etc/udev/rules.d" "$TEST_DIR/home"
}

# --- disk ---
fresh_root
output="$(runner FAKE_MNT_MOUNTED=0 bash "$REPO_ROOT/scripts/ci_runner.sh" disk 2>&1)"
if [[ "$output" == *"CI_WORK=$root/mnt/hurdkit-ci"* ]] &&
        grep -q "mount --bind $root/mnt/hurdkit-ci/gnu $root/gnu" "$TEST_DIR/calls" &&
        grep -q "mount --bind $root/mnt/hurdkit-ci/var-guix $root/var/guix" "$TEST_DIR/calls" &&
        grep -q "mount --bind $root/mnt/hurdkit-ci/cache $TEST_DIR/home/.cache/hurdkit-ci/store" "$TEST_DIR/calls" &&
        [[ -d "$root/usr/share/dotnet" ]]; then
    ok 'the second disk takes the store, the build directory and the saved store'
else
    not_ok 'the second disk takes the store' "$output"$'\n'"$(cat "$TEST_DIR/calls" 2>/dev/null)"
fi
fresh_root
output="$(runner FAKE_MNT_MOUNTED=1 FAKE_ROOT_FREE=40 bash "$REPO_ROOT/scripts/ci_runner.sh" disk 2>&1)"
if [[ "$output" == *"CI_WORK=$root/var/lib/hurdkit-ci"* && ! -e "$root/usr/share/dotnet" ]]; then
    ok 'without a second disk, / makes room and takes it'
else
    not_ok 'without a second disk, / makes room and takes it' "$output"
fi
fresh_root
if output="$(runner FAKE_MNT_MOUNTED=1 FAKE_ROOT_FREE=10 bash "$REPO_ROOT/scripts/ci_runner.sh" disk 2>&1)"; then
    not_ok 'too little space fails' "$output"
elif [[ "$output" == *"need 30"* ]]; then
    ok 'too little space fails and says how much is needed'
else
    not_ok 'too little space fails and says how much is needed' "$output"
fi
fresh_root
if output="$(runner FAKE_MNT_MOUNTED=0 FAKE_FSTYPE=btrfs FAKE_ROOT_FREE=40 bash "$REPO_ROOT/scripts/ci_runner.sh" disk 2>&1)"; then
    not_ok 'a build directory that is not on ext4 fails (G4)' "$output"
elif [[ "$output" == *"not ext4 (G4)"* ]]; then
    ok 'a build directory that is not on ext4 fails (G4)'
else
    not_ok 'a build directory that is not on ext4 fails (G4)' "$output"
fi

# --- kvm ---
fresh_root
touch "$root/dev-kvm-absent"
output="$(runner bash "$REPO_ROOT/scripts/ci_runner.sh" kvm 2>&1)"
if [[ "$output" == *"no /dev/kvm"* ]]; then ok 'without /dev/kvm, kvm only says so'; else not_ok 'without /dev/kvm' "$output"; fi
mkdir -p "$root/dev" && touch "$root/dev/kvm"
runner bash "$REPO_ROOT/scripts/ci_runner.sh" kvm >/dev/null 2>&1
if grep -q 'MODE="0666"' "$root/etc/udev/rules.d/99-kvm4all.rules" 2>/dev/null &&
        grep -q 'udevadm trigger --name-match=kvm' "$TEST_DIR/calls"; then
    ok 'kvm opens /dev/kvm to the runner with a udev rule'
else
    not_ok 'kvm opens /dev/kvm with a udev rule' "$(cat "$TEST_DIR/calls" 2>/dev/null)"
fi

# --- install-nix refuses an installer with another checksum ---
fresh_root
output="$(runner bash "$REPO_ROOT/scripts/ci_runner.sh" install-nix 2>&1)"
rc=$?
if (( rc != 0 )) && [[ "$output" == *"pinned checksum"* ]]; then
    ok 'an installer with another checksum is not run'
else
    not_ok 'an installer with another checksum is not run' "$output"
fi

# --- build users ---
fresh_root
runner bash "$REPO_ROOT/scripts/ci_runner.sh" guix-users 2>/dev/null
if grep -q '^groupadd --system guixbuild$' "$TEST_DIR/calls" &&
        [[ "$(grep -c '^useradd .*--gid guixbuild .*guixbuilder0[1-8]$' "$TEST_DIR/calls")" == 8 ]]; then
    ok 'the build group and its users are created'
else
    not_ok 'the build group and its users are created' "$(cat "$TEST_DIR/calls" 2>/dev/null)"
fi

# --- the daemon ---
fresh_root
mkdir -p "$root/work/build"
daemon() { runner CI_WORK="$root/work" bash "$REPO_ROOT/scripts/ci_runner.sh" guix-daemon 2>&1; }
output="$(daemon)"
rc=$?
args="$(cat "$TEST_DIR/systemd-run.args" 2>/dev/null)"
if (( rc == 0 )) &&
        grep -qx -- "--setenv=TMPDIR=$root/work/build" <<<"$args" &&
        grep -qx -- '--build-users-group=guixbuild' <<<"$args" &&
        grep -qx -- '--substitute-urls=https://bordeaux.guix.gnu.org https://ci.guix.gnu.org' <<<"$args" &&
        grep -q '^authorize (public-key bordeaux.guix.gnu.org)$' "$TEST_DIR/calls" &&
        grep -q '^authorize (public-key ci.guix.gnu.org)$' "$TEST_DIR/calls"; then
    ok 'the daemon builds in the ext4 directory and trusts the two farms'
else
    not_ok 'the daemon builds in the ext4 directory and trusts the two farms' "$output"$'\n'"$args"
fi
if grep -q -e 'generate-key' "$TEST_DIR/calls"; then
    not_ok 'no archive signing key is generated' "$(cat "$TEST_DIR/calls")"
else
    ok 'no archive signing key is generated'
fi
fresh_root
mkdir -p "$root/work/build" "$root/etc/guix"
touch "$root/etc/guix/signing-key.pub"
if output="$(daemon)"; then
    not_ok 'a machine with a signing key gets no daemon' "$output"
elif [[ ! -e "$TEST_DIR/systemd-run.args" || "$output" == *"signing-key.pub exists"* ]]; then
    ok 'a machine with a signing key gets no daemon'
else
    not_ok 'a machine with a signing key gets no daemon' "$output"
fi
if runner bash "$REPO_ROOT/scripts/ci_runner.sh" no-signing-key 2>/dev/null; then
    not_ok 'no-signing-key fails when there is one'
else
    ok 'no-signing-key fails when there is one'
fi

# --- saving and restoring the store ---
if ! command -v zstd >/dev/null 2>&1; then
    for test in 'the store is not saved while the daemon runs' \
            'the store and its database come back' 'without a saved store, restore starts empty' \
            'a new store item changes the fingerprint'; do
        number=$((number + 1))
        echo "ok $number - $test # SKIP zstd is required"
    done
    echo "1..$number"
    exit "$failures"
fi
fresh_root
mkdir -p "$root/gnu/store/aaaa-hello-1.0/bin" "$root/var/guix/db" "$root/var/guix/gcroots"
echo hello > "$root/gnu/store/aaaa-hello-1.0/bin/hello"
echo database > "$root/var/guix/db/db.sqlite"
echo root > "$root/var/guix/gcroots/link"
before="$(runner bash "$REPO_ROOT/scripts/ci_runner.sh" store-fingerprint)"
saved="$TEST_DIR/home/.cache/hurdkit-ci/store/guix-store.tar.zst"
if FAKE_DAEMON_ACTIVE=0 runner bash "$REPO_ROOT/scripts/ci_runner.sh" store-save "$saved" 2>/dev/null; then
    not_ok 'the store is not saved while the daemon runs'
else
    ok 'the store is not saved while the daemon runs'
fi
runner bash "$REPO_ROOT/scripts/ci_runner.sh" store-save "$saved" 2>/dev/null
rm -rf "${root:?}/gnu" "${root:?}/var"
runner bash "$REPO_ROOT/scripts/ci_runner.sh" store-restore "$saved" 2>/dev/null
after="$(runner bash "$REPO_ROOT/scripts/ci_runner.sh" store-fingerprint)"
if [[ "$(cat "$root/gnu/store/aaaa-hello-1.0/bin/hello" 2>/dev/null)" == hello &&
        "$(cat "$root/var/guix/db/db.sqlite" 2>/dev/null)" == database &&
        ! -e "$root/var/guix/gcroots/link" && "$before" == "$after" && ! -e "$saved" ]]; then
    ok 'the store and its database come back, and nothing else'
else
    not_ok 'the store and its database come back' "before $before after $after"
fi
if runner bash "$REPO_ROOT/scripts/ci_runner.sh" store-restore "$TEST_DIR/none.tar.zst" 2>/dev/null; then
    ok 'without a saved store, restore starts empty'
else
    not_ok 'without a saved store, restore starts empty'
fi
mkdir -p "$root/gnu/store/bbbb-new-1.0"
if [[ "$(runner bash "$REPO_ROOT/scripts/ci_runner.sh" store-fingerprint)" != "$after" ]]; then
    ok 'a new store item changes the fingerprint'
else
    not_ok 'a new store item changes the fingerprint'
fi

echo "1..$number"
exit "$failures"
