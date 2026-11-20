#!/usr/bin/env bash
# Build, check and describe the released images: the declarations in
# RELEASE_SYSTEMS, which have nothing of the machine that builds them.
# Run it inside "nix develop" (the guix command has to be goonix), on a
# machine whose Guix daemon is goonix too. See skills/GUIX.md, "Release
# images".
#
# Usage: guix_release.sh <command> [arguments]
#
#   check              say what building the images would build and download;
#                      fail when that includes a package other than goonix
#                      and this repository's own (pitfall G2)
#   prefetch           build or download everything the images need, but not
#                      the images themselves
#   build DIR          build the images into DIR as NAME-TAG.qcow2, check
#                      that no builder key is in them, write DIR/SHA256SUMS
#                      and DIR/NAME.manifest
#   smoke IMAGE [MANIFEST]
#                      boot IMAGE, log in as the release notes say, and check
#                      the guest's Guix (and its Hurd and processors when
#                      MANIFEST names them)
#   notes DIR          print the release notes of the images in DIR
#   publish DIR        create the GitHub release RELEASE_TAG from DIR with gh,
#                      or replace the files of an existing one
#
# Every setting below can be overridden from the environment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${GUIX_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
GUIX="${GUIX:-guix}"
# The released declarations. An image is named after its declaration
# without "-release.scm".
RELEASE_SYSTEMS="${RELEASE_SYSTEMS:-guix/hurd64-release.scm guix/hurd64-hurdkit-release.scm}"
# The name of the release; it goes into the file names of the images.
RELEASE_TAG="${RELEASE_TAG:-dev}"
# The largest release file that GitHub accepts (its documentation on
# releases states the limit).
RELEASE_MAX_BYTES="${RELEASE_MAX_BYTES:-2147483647}"
# Where the build keeps the GC roots of the images (outside of the
# directory that is published).
RELEASE_ROOTS="${RELEASE_ROOTS:-$REPO_ROOT/img/release-roots}"
# How often prefetch tries again after a failed download.
PREFETCH_ATTEMPTS="${PREFETCH_ATTEMPTS:-3}"
# The host port of the smoke test's guest, and how long one boot may take.
SMOKE_SSH_PORT="${SMOKE_SSH_PORT:-2240}"
SMOKE_MEMORY="${SMOKE_MEMORY:-2048}"
# The source of the release notes: the repository on GitHub.
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-hurdkit/hurdkit-guix}"
GH="${GH:-gh}"

die() {
    echo "guix_release: $*" >&2
    exit 1
}

say() {
    echo "guix_release: $*" >&2
}

indent() {
    local line
    while IFS= read -r line; do
        echo "guix_release:   $line"
    done
}

# The image has to be built by goonix, the Guix that flake.lock pins (G1).
require_goonix() {
    local version
    version="$("$GUIX" --version 2>/dev/null | sed -n 1p)" || true
    [[ "$version" == *goonix* ]] ||
        die "$GUIX is not goonix ('$version'); run this inside nix develop"
}

# A declaration of RELEASE_SYSTEMS as a file name: relative ones are in the
# repository.
declaration_file() {
    case "$1" in
        /*) echo "$1" ;;
        *) echo "$REPO_ROOT/$1" ;;
    esac
}

release_name() {
    local base
    base="$(basename "$1")"
    echo "${base%-release.scm}"
}

image_command() {
    "$GUIX" system image --load-path="$REPO_ROOT/guix/modules" \
        --image-type=hurd64-qcow2 "$@"
}

# The input derivations of the derivation file $1, one per line.
drv_inputs() {
    grep -o '("/[^"]*\.drv",\[' "$1" |
        sed 's/^("//; s/",\[$//' | sort -u
}

# The output paths of the derivation file $1, one per line.
drv_outputs() {
    sed 's/^Derive(\[//; s/)\],\[.*//' "$1" | grep -o '"/[^"]*"' | tr -d '"'
}

# The packages that are expected to be built here: goonix (guix/goonix.scm)
# and this repository's own packages (guix/modules), one name per line.
own_packages() {
    echo goonix
    sed -n 's/^(define-public \([a-z0-9-]*\)\( .*\)\{0,1\}$/\1/p' \
        "$REPO_ROOT"/guix/modules/hurdkit/packages/*.scm | grep -v '^%' | sort -u
}

# classify DRV: "cheap" for what Guix always makes here (system files,
# grafts, profile hooks and the image itself), "own" for a package of
# own_packages or its source checkout, "foreign" for any other package.
classify() {
    local drv="$1" name package
    name="$(basename "$drv" .drv)"
    name="${name:33}"
    if grep -q '("preferLocalBuild","1")' "$drv"; then
        echo cheap
        return
    fi
    # Packages are NAME-VERSION; system files and image parts have no
    # version.
    if [[ ! "$name" =~ -[0-9] ]]; then
        echo cheap
        return
    fi
    # The version starts with a digit, but so may a part of the name
    # (hurd-9pfs): the names of our packages are tried as prefixes.
    [[ -n "${OWN_PACKAGES:-}" ]] || OWN_PACKAGES="$(own_packages)"
    while read -r package; do
        if [[ "$name" == "$package"-[0-9]* ]]; then
            echo own
            return
        fi
    done <<<"$OWN_PACKAGES"
    echo foreign
}

# The derivations that "guix system image --dry-run" lists as to be built,
# from its output on standard input.
parse_dry_run() {
    tr '\r' '\n' | awk '
        /would be built:$/ { mode = 1; next }
        /would be downloaded:$/ { mode = 2; next }
        /^ +\// { if (mode == 1) print $1; next }
        { mode = 0 }'
}

# plan DECLARATION [OPTION...]: print "CLASS DRV" for each derivation that
# building DECLARATION would build. Fails if the dry run fails.
plan() {
    local declaration="$1" output drv
    shift
    output="$(image_command --dry-run "$@" "$(declaration_file "$declaration")" 2>&1)" || {
        printf '%s\n' "$output" | tail -n 20 >&2
        die "guix system image --dry-run failed for $declaration"
    }
    while read -r drv; do
        [[ -n "$drv" ]] || continue
        echo "$(classify "$drv") $drv"
    done < <(parse_dry_run <<<"$output")
}

# gate DECLARATION: decide how to build DECLARATION and print the guix
# options for it. With a filled store only cheap derivations are missing:
# then nothing is asked from the build farms (--no-substitutes). Otherwise
# the farms have to provide every package but goonix and our own; a package
# that they do not provide means that a farm is down or that the goonix
# pin left the commits the farms built (G2), and building it here would
# take hours, so the gate fails.
gate() {
    local declaration="$1" planned foreign own
    planned="$(plan "$declaration" --no-substitutes)" || return 1
    if ! grep -qv -e '^cheap ' -e '^$' <<<"$planned"; then
        say "$declaration: the store has every package; nothing is downloaded"
        echo --no-substitutes
        return 0
    fi
    planned="$(plan "$declaration")" || return 1
    foreign="$(grep '^foreign ' <<<"$planned" | cut -d' ' -f2- || true)"
    own="$(grep '^own ' <<<"$planned" | cut -d' ' -f2- || true)"
    if [[ -n "$foreign" ]]; then
        {
            echo "guix_release: $declaration: these packages would be built here, because"
            echo "guix_release: no substitute server offers them:"
            indent <<<"$foreign"
            echo "guix_release: Either a build farm (bordeaux.guix.gnu.org, ci.guix.gnu.org) does"
            echo "guix_release: not answer, or the goonix pin is not a commit the farms built"
            echo "guix_release: (skills/GUIX.md, G2). Building them would take hours; stopping."
        } >&2
        return 1
    fi
    if [[ -n "$own" ]]; then
        say "$declaration: built here (goonix and our own packages):"
        indent <<<"$own" >&2
    fi
    # No --fallback: a substitute that fails to download stops the build
    # instead of building that package here.
    echo ""
}

cmd_check() {
    require_goonix
    local declaration failed=0
    for declaration in $RELEASE_SYSTEMS; do
        ( gate "$declaration" >/dev/null ) || failed=1
    done
    (( failed == 0 )) || die "the build would not use substitutes as expected"
    say "check passed"
}

# The derivations of DECLARATION's image that make the image itself: the
# disk image, its genimage configuration and the partition images. Their
# outputs are large and are rebuilt from the rest in minutes.
image_chain() {
    local image_drv="$1" genimage partitions
    genimage="$(drv_inputs "$image_drv" | grep -- '-genimage\.cfg\.drv$' || true)"
    [[ -n "$genimage" ]] ||
        die "$image_drv has no genimage.cfg input; the image derivations of goonix changed, adapt image_chain"
    partitions="$(drv_inputs "$genimage" | grep -- '-partition\.img\.drv$' || true)"
    [[ -n "$partitions" ]] ||
        die "$genimage has no partition.img input; the image derivations of goonix changed, adapt image_chain"
    printf '%s\n' "$image_drv" "$genimage" "$partitions"
}

# The derivations that the image chain of DECLARATION needs.
prerequisites() {
    local declaration="$1" image_drv chain drv
    image_drv="$(image_command --derivation "$(declaration_file "$declaration")" | tail -n 1)"
    [[ "$image_drv" == /gnu/store/*.drv ]] || die "no image derivation for $declaration"
    chain="$(image_chain "$image_drv")"
    for drv in $chain; do
        drv_inputs "$drv"
    done | sort -u | grep -vxF -f <(printf '%s\n' "$chain")
}

cmd_prefetch() {
    require_goonix
    local declaration options
    local -a drvs
    local attempt
    for declaration in $RELEASE_SYSTEMS; do
        options="$(gate "$declaration")" || die "stopping before the build"
        mapfile -t drvs < <(prerequisites "$declaration")
        (( ${#drvs[@]} > 0 )) || die "no prerequisites found for $declaration"
        # A download that breaks off fails the build; what was fetched stays
        # in the store, so another attempt fetches only the rest.
        for (( attempt = 1; ; attempt++ )); do
            say "$declaration: building what the image needs (attempt $attempt)"
            # shellcheck disable=SC2086
            "$GUIX" build $options "${drvs[@]}" >/dev/null && break
            (( attempt < PREFETCH_ATTEMPTS )) || die "prefetch failed for $declaration"
        done
    done
    say "prefetch done"
}

# The system directory of an image derivation: the input of its partition
# image that is named "system".
image_system() {
    local image_drv="$1" drv
    for drv in $(image_chain "$image_drv"); do
        drv_inputs "$drv"
    done | grep -- '-system\.drv$' | sort -u | while read -r drv; do
        drv_outputs "$drv"
    done | sed -n 1p
}

# The SSH key material (the base64 field) of the public keys in img/keys
# and of the archive signing key of this machine: what must not be in an
# image that is released.
builder_key_material() {
    local file
    for file in "$REPO_ROOT"/img/keys/*.pub; do
        if [[ -f "$file" ]]; then
            awk '{print $2}' "$file"
        fi
    done
    if [[ -r /etc/guix/signing-key.pub ]]; then
        # The "q" field of the public key, as written in an ACL.
        grep -o '#[0-9A-F]*#' /etc/guix/signing-key.pub || true
    fi
    return 0
}

# check_no_builder_keys SYSTEM PARTITION: the released system authorizes no
# SSH key and trusts only the archive keys that goonix ships, and the root
# partition of the image contains no key of the building machine.
check_no_builder_keys() {
    local system="$1" partition="$2" closure item acl q goonix_keys material
    # The first column of guix size's table: the items, by absolute name.
    closure="$("$GUIX" size "$system" | awk '$1 ~ /^\// {print $1}')"
    [[ -n "$closure" ]] || die "could not list the closure of $system"
    item="$(grep -E -- '-(host-signing-key\.pub|[a-z]+_ed25519\.pub)$' <<<"$closure" || true)"
    [[ -z "$item" ]] || die "the released system contains a key of the building machine: $item"
    # sshd's directory of authorized keys exists, and has to be empty.
    for item in $(grep -E -- '-openssh-authorized-keys$' <<<"$closure" || true); do
        [[ -z "$(find "$item" -mindepth 1 -print -quit)" ]] ||
            die "the released system authorizes SSH keys: $item"
    done
    acl="$(grep -E -- '-acl$' <<<"$closure" || true)"
    [[ -n "$acl" ]] || die "no ACL of the guest's Guix in the closure of $system"
    goonix_keys="$(dirname "$(dirname "$(readlink -f "$(command -v "$GUIX")")")")/share/guix"
    while read -r q; do
        grep -qF -- "$q" "$goonix_keys"/*.pub ||
            die "the guest's Guix trusts a key that goonix does not ship ($acl)"
    done < <(while read -r item; do grep -o '#[0-9A-F]*#' "$item"; done <<<"$acl" | sort -u)
    for material in $(builder_key_material); do
        if grep -qaF -- "$material" "$partition"; then
            die "the image's root partition contains a key of this machine"
        fi
    done
}

# check_translators PARTITION-DRV: the root partition was built with its
# translators. Where the daemon's build directory cannot hold gnu.*
# extended attributes, the build only warns and the guest does not come up
# (G4).
check_translators() {
    local log
    log="$("$GUIX" build --log-file "$1" 2>/dev/null)" || {
        say "no build log of $1; cannot check its translators (G4)"
        return 0
    }
    local lost
    lost="$(zcat -f "$log" | bzcat -f | grep -c -e 'Operation not supported' -e 'Good Luck' || true)"
    (( lost == 0 )) ||
        die "the root partition lost its translators ($log): the daemon's build directory must be on ext4 (G4)"
}

# A store item's name without its hash.
store_name() {
    basename "$1" | cut -c34-
}

cmd_build() {
    (( $# == 1 )) || die "usage: guix_release.sh build DIR"
    require_goonix
    local dir="$1" declaration name options image_drv store_image system \
        partition_drv partition file size
    mkdir -p "$dir" "$RELEASE_ROOTS"
    dir="$(cd "$dir" && pwd)"
    for declaration in $RELEASE_SYSTEMS; do
        name="$(release_name "$declaration")"
        options="$(gate "$declaration")" || die "stopping before the build"
        image_drv="$(image_command --derivation "$(declaration_file "$declaration")" | tail -n 1)"
        # guix refuses to replace a GC root (G18).
        rm -f "$RELEASE_ROOTS/$name"
        say "$declaration: building the image"
        # shellcheck disable=SC2086
        store_image="$(image_command $options --root="$RELEASE_ROOTS/$name" \
            "$(declaration_file "$declaration")" | tail -n 1)"
        [[ -f "$store_image" ]] || die "guix did not produce an image for $declaration"
        [[ "$store_image" == "$(drv_outputs "$image_drv")" ]] ||
            die "$store_image is not the output of $image_drv"
        system="$(image_system "$image_drv")"
        partition_drv="$(image_chain "$image_drv" | grep -- '-partition\.img\.drv$' | sed -n 1p)"
        partition="$(drv_outputs "$partition_drv" | sed -n 1p)"
        [[ -d "$system" && -f "$partition" ]] ||
            die "the system or the root partition of $store_image is not in the store"
        check_translators "$partition_drv"
        check_no_builder_keys "$system" "$partition"
        file="$name-$RELEASE_TAG.qcow2"
        rm -f "$dir/$file"
        cp "$store_image" "$dir/$file"
        chmod 644 "$dir/$file"
        size="$(stat -c %s "$dir/$file")"
        (( size <= RELEASE_MAX_BYTES )) ||
            die "$file has $size bytes, more than a release file may have"
        {
            echo "image $file"
            echo "declaration $declaration"
            echo "store-image $store_image"
            echo "derivation $image_drv"
            echo "system $system"
            echo "kernel $(store_name "$(readlink -f "$system/kernel")")"
            echo "hurd $(store_name "$(readlink -f "$system/hurd")")"
            echo "cpus $(kernel_cpus "$system")"
        } > "$dir/$name.manifest"
        say "$declaration: $dir/$file"
    done
    (cd "$dir" && sha256sum -- *.qcow2 > SHA256SUMS)
    say "checksums in $dir/SHA256SUMS"
}

# The processors that the kernel of SYSTEM is built for: the --enable-ncpus
# of gnumach-hurdkit-smp, else one.
kernel_cpus() {
    local kernel cpus=""
    kernel="$(store_name "$(readlink -f "$1/kernel")")"
    if [[ "$kernel" == gnumach-hurdkit-smp-* ]]; then
        cpus="$(sed -n 's/^(define %gnumach-smp-cpus \([0-9]*\))$/\1/p' \
            "$REPO_ROOT/guix/modules/hurdkit/packages/hurd.scm")"
    fi
    echo "${cpus:-1}"
}

# The manifests in DIR, in the order of RELEASE_SYSTEMS.
manifests() {
    local declaration file
    for declaration in $RELEASE_SYSTEMS; do
        file="$1/$(release_name "$declaration").manifest"
        [[ -f "$file" ]] || die "no $file; run build first"
        echo "$file"
    done
}

manifest_value() {
    awk -v key="$2" '$1 == key { sub(/^[^ ]* /, ""); print; exit }' "$1"
}

cmd_smoke() {
    (( $# >= 1 && $# <= 2 )) || die "usage: guix_release.sh smoke IMAGE [MANIFEST]"
    local image manifest="${2:-}" dir cpus=1 hurd="" output rc=0
    image="$(readlink -f "$1")"
    [[ -f "$image" ]] || die "no image: $1"
    if [[ -n "$manifest" ]]; then
        cpus="$(manifest_value "$manifest" cpus)"
        hurd="$(manifest_value "$manifest" hurd)"
    fi
    dir="$(mktemp -d "${TMPDIR:-/tmp}/guix-release-smoke.XXXXXX")"
    # guix_vm.sh boots an overlay of its base image; the released file is
    # that base, unchanged.
    ln -s "$image" "$dir/hurd64.base.qcow2"
    local -a vm=(env GUIX_DIR="$dir" GUIX_SSH_PORT="$SMOKE_SSH_PORT"
        GUIX_LOGIN=empty-password GUIX_MEMORY="$SMOKE_MEMORY"
        GUIX_CPUS="$([[ "$cpus" == 1 ]] || echo "$cpus")"
        GUIX_DISPLAY=none GUIX_GPU=none
        bash "$SCRIPT_DIR/guix_vm.sh")
    if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
        # Without KVM a boot takes many minutes.
        vm=(env GUIX_BOOT_TIMEOUT="${GUIX_BOOT_TIMEOUT:-1200}" "${vm[@]}")
    fi
    say "booting $image (port $SMOKE_SSH_PORT, $cpus processor(s))"
    if ! "${vm[@]}" start; then
        say "the guest did not let root in; serial logs in $dir"
        return 1
    fi
    smoke_checks || rc=1
    "${vm[@]}" stop || { say "the guest did not halt cleanly"; rc=1; }
    if (( rc == 0 )); then
        rm -rf "$dir"
        say "smoke test passed: $image"
    else
        say "smoke test failed; serial logs in $dir"
    fi
    return "$rc"
}

# The checks of a booted release guest; vm, cpus and hurd come from
# cmd_smoke.
smoke_checks() {
    local output others
    output="$("${vm[@]}" ssh root guix --version)" || {
        say "guix --version failed in the guest"; return 1; }
    output="${output%%$'\n'*}"
    [[ "$output" == *goonix* ]] || { say "the guest's Guix is not goonix: $output"; return 1; }
    say "guest: $output"
    if [[ -n "$hurd" ]]; then
        # Every translator runs from the system's Hurd, and no other.
        output="$("${vm[@]}" ssh root ps -ef)" || { say "ps failed in the guest"; return 1; }
        grep -q -- "-$hurd/hurd/" <<<"$output" ||
            { say "no translator of $hurd runs in the guest"; return 1; }
        others="$(grep -o '/gnu/store/[a-z0-9]\{32\}-hurd[^/ ]*/hurd/' <<<"$output" |
            grep -v -- "-$hurd/hurd/" | sort -u || true)"
        [[ -z "$others" ]] || { say "translators of another Hurd run: $others"; return 1; }
        say "guest: every translator is from $hurd"
    fi
    output="$("${vm[@]}" ssh root nproc)" || { say "nproc failed in the guest"; return 1; }
    [[ "$output" == "$cpus" ]] ||
        { say "the guest uses $output processor(s), expected $cpus"; return 1; }
    say "guest: $output processor(s)"
}

pin() {
    sed -n "s/^(define $1 \"\\([0-9a-f]*\\)\")\$/\\1/p" "$2"
}

cmd_notes() {
    (( $# == 1 )) || die "usage: guix_release.sh notes DIR"
    local dir="$1" manifest list file goonix gnumach hurd cpus smp_option version
    list="$(manifests "$dir")" || exit 1
    goonix="$(pin %goonix-commit "$REPO_ROOT/guix/goonix.scm")"
    gnumach="$(pin %gnumach-hurdkit-commit "$REPO_ROOT/guix/modules/hurdkit/packages/hurd.scm")"
    hurd="$(pin %hurd-hurdkit-commit "$REPO_ROOT/guix/modules/hurdkit/packages/hurd.scm")"
    [[ -n "$goonix" && -n "$gnumach" && -n "$hurd" ]] || die "could not read the pins"
    version="$("$GUIX" --version 2>/dev/null | sed -n 1p)" || true
    cat <<EOF
64-bit GNU/Hurd guests built from \`$RELEASE_TAG\` of this repository by
[goonix](https://github.com/hurdkit/goonix), our fork of GNU Guix.

## Images

| File | Declaration | GNU Mach | Hurd |
|---|---|---|---|
EOF
    for manifest in $list; do
        echo "| \`$(manifest_value "$manifest" image)\` | \`$(manifest_value "$manifest" declaration)\` | \`$(manifest_value "$manifest" kernel)\` | \`$(manifest_value "$manifest" hurd)\` |"
    done
    cat <<EOF

The files are compressed qcow2 images as \`guix system image\` writes them.
\`sha256sum -c SHA256SUMS\` checks them.

## Pins

- goonix: [\`$goonix\`](https://github.com/hurdkit/goonix/commit/$goonix)
- GNU Mach of \`hurd64-hurdkit\`: [\`$gnumach\`](https://github.com/hurdkit/gnumach/commit/$gnumach)
- Hurd of \`hurd64-hurdkit\`: [\`$hurd\`](https://github.com/hurdkit/hurd/commit/$hurd)
- built with: \`${version:-unknown}\`

The other packages, and the GNU Mach and Hurd of \`hurd64\`, are those of
the upstream Guix commit that goonix is based on.

## Boot

EOF
    for manifest in $list; do
        file="$(manifest_value "$manifest" image)"
        cpus="$(manifest_value "$manifest" cpus)"
        smp_option=""
        [[ "$cpus" == 1 ]] || smp_option=" -smp $cpus"
        cat <<EOF
\`$file\`:

\`\`\`sh
qemu-system-x86_64 -M q35 -enable-kvm -m 2048$smp_option -snapshot \\
    -hda $file \\
    -device e1000,netdev=net0 \\
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2223-:2222 -nographic
\`\`\`

EOF
    done
    cat <<EOF
Then, from another terminal:

\`\`\`sh
ssh -p 2223 root@127.0.0.1
\`\`\`

- \`root\` has an empty password, and the guest's sshd (port 2222) accepts
  it, as in upstream Guix's bare-hurd64 template. Whoever reaches that port
  is root: keep the forward bound to \`127.0.0.1\` as above, and never
  forward it from an address that others can reach.
- \`-M q35\` is required; the default machine type gives the 64-bit Hurd
  memory problems.
- \`-snapshot\` discards what the guest writes. For a disk that keeps it,
  copy the image first (\`qemu-img convert -O qcow2 FILE disk.qcow2\`) and
  boot the copy without \`-snapshot\`.
- The guest sometimes hangs at boot, before sshd starts; boot it again.
- \`halt\` in the guest stops the Hurd but does not power the machine off;
  quit QEMU after "Shutdown completed successfully" (Ctrl-A X).

Source: https://github.com/$GITHUB_REPOSITORY/tree/$RELEASE_TAG
EOF
}

cmd_publish() {
    (( $# == 1 )) || die "usage: guix_release.sh publish DIR"
    local dir="$1"
    [[ "$RELEASE_TAG" != dev ]] || die "set RELEASE_TAG to the tag to release"
    [[ -f "$dir/SHA256SUMS" && -f "$dir/notes.md" ]] ||
        die "$dir has no SHA256SUMS or notes.md; run build and notes first"
    (cd "$dir" && sha256sum --quiet -c SHA256SUMS) || die "the files in $dir do not match SHA256SUMS"
    local -a files=("$dir"/*.qcow2 "$dir/SHA256SUMS")
    if "$GH" release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
        say "release $RELEASE_TAG exists; replacing its files"
        "$GH" release upload "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --clobber "${files[@]}"
        "$GH" release edit "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --notes-file "$dir/notes.md"
    else
        "$GH" release create "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --verify-tag \
            --title "$RELEASE_TAG" --notes-file "$dir/notes.md" "${files[@]}"
    fi
}

command="${1:-}"
[[ $# -gt 0 ]] && shift
case "$command" in
    check) cmd_check "$@" ;;
    prefetch) cmd_prefetch "$@" ;;
    build) cmd_build "$@" ;;
    smoke) cmd_smoke "$@" ;;
    notes) cmd_notes "$@" ;;
    publish) cmd_publish "$@" ;;
    *)
        sed -n '2,/^$/s/^# \{0,1\}//p' "$0" >&2
        exit 2
        ;;
esac
