#!/usr/bin/env bash
# TAP: scripts/guix_release.sh against a synthetic guix, synthetic
# derivations and a synthetic gh; nothing is built and no guest is booted.
# With goonix (nix develop) and its daemon, it also finds the image
# derivations of the released declarations. And the released declarations
# read nothing of the machine that builds them.
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
# expect DESCRIPTION EXPECTED ACTUAL
expect() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else not_ok "$1" "expected: $2"$'\n'"got: $3"; fi
}

# The functions of the script, without running a command.
release() {
    GUIX_REPO_ROOT="$REPO_ROOT" bash -c '
        source <(sed "/^command=/,\$d" "$1/scripts/guix_release.sh")
        shift
        "$@"' _ "$REPO_ROOT" "$@"
}

store="$TEST_DIR/gnu/store"
mkdir -p "$store"
hash() { printf '%032d' "$1" | tr 0-9 a-j; }
# drv N NAME [ENV] [INPUT-DRV...]: a derivation file in the shape Guix
# writes, with one output.
drv() {
    local n="$1" name="$2" env="$3" input inputs=""
    shift 3
    for input in "$@"; do
        inputs+="${inputs:+,}(\"$input\",[\"out\"])"
    done
    printf 'Derive([("out","/gnu/store/%s-%s","","")],[%s],[],"x86_64-linux","/bin/guile",[],[%s])' \
        "$(hash "$n")" "$name" "$inputs" "$env" > "$store/$(hash "$n")-$name.drv"
    echo "$store/$(hash "$n")-$name.drv"
}

# --- Classifying what a build would build ---
local_flag='("preferLocalBuild","1")'
d_graft="$(drv 1 qemu-minimal-10.2.1 "$local_flag,(\"guix properties\",\"((type . graft))\")")"
d_glue="$(drv 2 shepherd.conf '')"
d_own="$(drv 3 gnumach-hurdkit-smp-1.8-2.7944a94 '')"
d_goonix="$(drv 4 goonix-1.5.0-goonix.630ee30 '')"
d_foreign="$(drv 5 qemu-minimal-10.2.1 '')"
d_checkout="$(drv 6 hurd-hurdkit-0.9-2.7825c34-checkout '')"
expect 'a graft is cheap' cheap "$(release classify "$d_graft")"
expect 'a system file without a version is cheap' cheap "$(release classify "$d_glue")"
expect 'a package of guix/modules is our own' own "$(release classify "$d_own")"
expect 'goonix is our own' own "$(release classify "$d_goonix")"
expect 'the source of our own package is our own' own "$(release classify "$d_checkout")"
expect 'any other package is foreign' foreign "$(release classify "$d_foreign")"
d_digit="$(drv 23 hurd-9pfs-0-1.b5b23de '')"
expect 'a package of ours with a dash and a digit in its name is our own' own \
    "$(release classify "$d_digit")"
d_prefix="$(drv 24 hurd-0.9.git20251029-0.6290b4c '')"
expect 'a package whose name is a part of ours is foreign' foreign "$(release classify "$d_prefix")"

dry_run="substitute: looking for substitutes on 'https://bordeaux.guix.gnu.org'...  50.0%"$'\r'"substitute: done
The following derivations would be built:
  $d_graft
  $d_own
12.5 MB would be downloaded:
  /gnu/store/$(hash 9)-guile-3.0.9
guix system: warning: Consider running 'guix pull'"
expect 'the dry run lists what would be built, not what would be downloaded' \
    "$d_graft"$'\n'"$d_own" "$(release parse_dry_run <<<"$dry_run")"

# --- The gate (G2), with a guix that prints a canned dry run ---
mkdir -p "$TEST_DIR/goonix/bin" "$TEST_DIR/goonix/share/guix"
cat > "$TEST_DIR/goonix/bin/guix" <<'SH'
#!/usr/bin/env bash
case "$*" in
    --version) echo "guix (GNU Guix) ${FAKE_VERSION:-1.5.0-goonix.630ee30}"; exit 0 ;;
esac
if [[ "$*" == *--dry-run* ]]; then
    if [[ "$*" == *--no-substitutes* ]]; then
        list="$PLAN_LOCAL"
    else
        list="$PLAN_SUBSTITUTES"
    fi
    if [[ -n "$list" ]]; then
        echo "The following derivations would be built:" >&2
        for drv in $list; do echo "   $drv" >&2; done
    fi
    exit 0
fi
if [[ "$1" == size ]]; then
    echo "store item   total   self"
    cat "$TEST_DIR/closure"
    echo "total: 1 MiB"
    exit 0
fi
echo "unexpected guix $*" >&2
exit 1
SH
chmod +x "$TEST_DIR/goonix/bin/guix"
export GUIX="$TEST_DIR/goonix/bin/guix"
gate() {
    PLAN_LOCAL="$1" PLAN_SUBSTITUTES="$2" release gate guix/hurd64-release.scm 2>"$TEST_DIR/gate.err"
}
output="$(gate "$d_graft $d_glue" "")"
expect 'with a filled store, nothing is asked from the farms' --no-substitutes "$output"
output="$(gate "$d_graft $d_own $d_foreign" "$d_graft $d_own")"
rc=$?
expect 'with farms that have every foreign package, the gate passes with substitutes' "0 " "$rc $output"
if gate "$d_graft $d_own $d_foreign" "$d_own $d_foreign" >/dev/null; then
    not_ok 'a foreign package that no farm offers stops the gate'
elif grep -q 'G2' "$TEST_DIR/gate.err" && grep -q "$(basename "$d_foreign")" "$TEST_DIR/gate.err"; then
    ok 'a foreign package that no farm offers stops the gate, naming it and G2'
else
    not_ok 'the gate names the package and G2' "$(cat "$TEST_DIR/gate.err")"
fi
if FAKE_VERSION=1.5.0 release require_goonix 2>/dev/null; then
    not_ok 'a guix that is not goonix is refused (G1)'
else
    ok 'a guix that is not goonix is refused (G1)'
fi

# --- The image chain and what the image needs ---
d_tool="$(drv 10 genimage-19 "$local_flag")"
d_system="$(drv 11 system "$local_flag")"
d_partition="$(drv 12 partition.img '' "$d_system" "$d_tool")"
d_genimage="$(drv 13 genimage.cfg "$local_flag" "$d_partition")"
d_image="$(drv 14 disk-image '' "$d_genimage" "$d_tool")"
expect 'the image chain is the disk image, its genimage.cfg and the partition' \
    "$d_image"$'\n'"$d_genimage"$'\n'"$d_partition" "$(release image_chain "$d_image")"
expect 'the system of an image is the output of its system derivation' \
    "/gnu/store/$(hash 11)-system" "$(release image_system "$d_image")"
expect 'the inputs of a derivation' "$d_tool"$'\n'"$d_system" \
    "$(release drv_inputs "$d_partition" | sort)"
if release image_chain "$d_system" 2>/dev/null; then
    not_ok 'an image derivation of another shape is refused'
else
    ok 'an image derivation of another shape is refused'
fi

# --- No key of the builder in the released system ---
keys="$TEST_DIR/goonix/share/guix"
printf '(public-key (ecc (curve Ed25519) (q #AAAA#)))\n' > "$keys/bordeaux.guix.gnu.org.pub"
printf '(public-key (ecc (curve Ed25519) (q #BBBB#)))\n' > "$keys/ci.guix.gnu.org.pub"
items="$TEST_DIR/items"
mkdir -p "$items/aaa-openssh-authorized-keys" "$items/fake-repo/img/keys"
printf '(acl (entry (public-key (ecc (curve Ed25519) (q #AAAA#)))) (entry (public-key (ecc (curve Ed25519) (q #BBBB#)))))\n' > "$items/bbb-acl"
partition="$TEST_DIR/partition.img"
printf 'ext2 data without keys\n' > "$partition"
printf '%s\n' "$items/aaa-openssh-authorized-keys" "$items/bbb-acl" > "$TEST_DIR/closure"
no_keys() {
    GUIX_REPO_ROOT="$items/fake-repo" bash -c '
        source <(sed "/^command=/,\$d" "$1/scripts/guix_release.sh")
        builder_key_material() { printf "%s\n" "${KEY_MATERIAL:-}"; }
        check_no_builder_keys "$2" "$3"' _ "$REPO_ROOT" "$items/system" "$partition" 2>"$TEST_DIR/keys.err"
}
if no_keys; then ok 'a system with the farm keys only and no SSH key passes'; else not_ok 'a clean system passes' "$(cat "$TEST_DIR/keys.err")"; fi
printf 'ssh-ed25519 AAAAC3fake root@hurd\n' > "$items/aaa-openssh-authorized-keys/root.pub"
if no_keys; then not_ok 'an authorized SSH key is found'; else ok 'an authorized SSH key is found'; fi
rm "$items/aaa-openssh-authorized-keys/root.pub"
printf '(acl (entry (public-key (ecc (curve Ed25519) (q #AAAA#)))) (entry (public-key (ecc (curve Ed25519) (q #CCCC#)))))\n' > "$items/bbb-acl"
if no_keys; then not_ok 'a trusted key that goonix does not ship is found'; else ok 'a trusted key that goonix does not ship (the host key) is found'; fi
printf '(acl (entry (public-key (ecc (curve Ed25519) (q #AAAA#)))))\n' > "$items/bbb-acl"
printf 'ext2 data with #CCCC# inside\n' > "$partition"
if KEY_MATERIAL='#CCCC#' no_keys; then not_ok 'key material in the partition is found'; else ok 'key material of this machine in the root partition is found'; fi

# --- Release notes ---
release_dir="$TEST_DIR/release"
mkdir -p "$release_dir"
printf 'image hurd64-v9.qcow2\ndeclaration guix/hurd64-release.scm\nkernel gnumach-1.8\nhurd hurd-0.9\ncpus 1\n' > "$release_dir/hurd64.manifest"
printf 'image hurd64-hurdkit-v9.qcow2\ndeclaration guix/hurd64-hurdkit-release.scm\nkernel gnumach-hurdkit-smp-1.8\nhurd hurd-hurdkit-0.9\ncpus 2\n' > "$release_dir/hurd64-hurdkit.manifest"
notes="$(RELEASE_TAG=v9 release cmd_notes "$release_dir" 2>/dev/null)"
goonix_pin="$(sed -n 's/^(define %goonix-commit "\([0-9a-f]*\)")$/\1/p' "$REPO_ROOT/guix/goonix.scm")"
hurd_pin="$(sed -n 's/^(define %hurd-hurdkit-commit "\([0-9a-f]*\)")$/\1/p' "$REPO_ROOT/guix/modules/hurdkit/packages/hurd.scm")"
mach_pin="$(sed -n 's/^(define %gnumach-hurdkit-commit "\([0-9a-f]*\)")$/\1/p' "$REPO_ROOT/guix/modules/hurdkit/packages/hurd.scm")"
missing=""
for needle in "$goonix_pin" "$hurd_pin" "$mach_pin" '-M q35' 'hostfwd=tcp:127.0.0.1:2223-:2222' \
        'empty password' 'ssh -p 2223 root@127.0.0.1' '-smp 2 -snapshot' 'hurd64-v9.qcow2' \
        'tree/v9'; do
    [[ -n "$needle" && "$notes" == *"$needle"* ]] || missing+="$needle"$'\n'
done
if [[ -z "$missing" ]]; then
    ok 'the notes name the pins, the QEMU command and the login'
else
    not_ok 'the notes name the pins, the QEMU command and the login' "missing: $missing"
fi
plain_line="$(grep -n -F -- '-hda hurd64-v9.qcow2' <<<"$notes" | head -n 1)"
expect 'the plain image boots on one processor' '' "$(sed -n "$((${plain_line%%:*} - 1))p" <<<"$notes" | grep -o -- '-smp [0-9]*')"

# --- Publishing, with a gh that records its arguments ---
cat > "$TEST_DIR/goonix/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_DIR/gh.log"
[[ "$1 $2" == "release view" ]] && exit "${FAKE_RELEASE_EXISTS:-1}"
exit 0
SH
chmod +x "$TEST_DIR/goonix/bin/gh"
printf 'qcow2\n' > "$release_dir/hurd64-v9.qcow2"
printf 'qcow2\n' > "$release_dir/hurd64-hurdkit-v9.qcow2"
(cd "$release_dir" && sha256sum -- *.qcow2 > SHA256SUMS)
printf 'notes\n' > "$release_dir/notes.md"
publish() { GH="$TEST_DIR/goonix/bin/gh" RELEASE_TAG="${1:-v9}" release cmd_publish "$release_dir" >/dev/null 2>&1; }
rm -f "$TEST_DIR/gh.log"
if publish && grep -q '^release create v9 .*--verify-tag.*SHA256SUMS' "$TEST_DIR/gh.log"; then
    ok 'a new tag gets a release with the images and SHA256SUMS'
else
    not_ok 'a new tag gets a release' "$(cat "$TEST_DIR/gh.log" 2>/dev/null)"
fi
rm -f "$TEST_DIR/gh.log"
if FAKE_RELEASE_EXISTS=0 publish && grep -q '^release upload v9 .*--clobber' "$TEST_DIR/gh.log" &&
        ! grep -q '^release create' "$TEST_DIR/gh.log"; then
    ok 'an existing release gets its files replaced'
else
    not_ok 'an existing release gets its files replaced' "$(cat "$TEST_DIR/gh.log" 2>/dev/null)"
fi
printf 'changed\n' > "$release_dir/hurd64-v9.qcow2"
rm -f "$TEST_DIR/gh.log"
if publish || [[ -s "$TEST_DIR/gh.log" ]]; then
    not_ok 'files that do not match SHA256SUMS are not published'
else
    ok 'files that do not match SHA256SUMS are not published'
fi
if publish dev; then not_ok 'the default tag is never published'; else ok 'the default tag is never published'; fi

# --- The released declarations ---
unset GUIX
found="$(grep -n -e 'img/keys' -e 'signing-key' -e '(load "hurd64.scm")' \
    "$REPO_ROOT/guix/hurd64-base.scm" "$REPO_ROOT/guix/hurd64-release.scm" \
    "$REPO_ROOT/guix/hurd64-hurdkit-release.scm" | grep -v ';;' || true)"
if [[ -z "$found" ]]; then
    ok 'the released declarations read no key and do not load guix/hurd64.scm'
else
    not_ok 'the released declarations read no key and do not load guix/hurd64.scm' "$found"
fi

# --- With goonix: the image derivations have the shape image_chain knows ---
if ! guix --version 2>/dev/null | head -n 1 | grep -q goonix ||
        ! guix build --version >/dev/null 2>&1 ||
        [[ ! -S "${GUIX_DAEMON_SOCKET:-/var/guix/daemon-socket/socket}" ]]; then
    for declaration in guix/hurd64-release.scm guix/hurd64-hurdkit-release.scm; do
        number=$((number + 1))
        echo "ok $number - the image chain of $declaration is found # SKIP needs goonix and its daemon (nix develop)"
    done
else
    export GUILE_AUTO_COMPILE=0
    for declaration in guix/hurd64-release.scm guix/hurd64-hurdkit-release.scm; do
        if chain="$(GUIX=guix release prerequisites "$declaration" 2>"$TEST_DIR/chain.err")" &&
                grep -q -- '-system\.drv$' <<<"$chain"; then
            ok "the image chain of $declaration is found"
        else
            not_ok "the image chain of $declaration is found" "$(tail -n 5 "$TEST_DIR/chain.err")"
        fi
    done
fi

echo "1..$number"
exit "$failures"
