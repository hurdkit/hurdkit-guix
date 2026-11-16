#!/usr/bin/env bash
# TAP: every package of guix/modules and every system declaration in guix/
# evaluates with goonix, and the module path does not change the plain
# guest. Nothing is built: "guix build -n" and derivations only.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1
GUIX="${GUIX:-guix}"
if ! "$GUIX" --version 2>/dev/null | head -n 1 | grep -q goonix; then
    echo '1..0 # SKIP needs goonix (nix develop ./nix#guix)'
    exit 0
fi
export GUILE_AUTO_COMPILE=0

# The packages that guix/modules defines, by name.
mapfile -t packages < <(sed -n 's/^(define-public \([a-z0-9-]*\)$/\1/p;
    s/^(define-public \([a-z0-9-]*\) .*/\1/p' guix/modules/hurdkit/packages/*.scm |
    grep -v '^%' | sort -u)
mapfile -t systems < <(ls guix/hurd64*.scm)

echo "1..$(( ${#packages[@]} + ${#systems[@]} + 1 ))"
failures=0
number=0
check() {
    local description="$1"; shift
    number=$((number + 1))
    if "$@" >/dev/null 2>"$REPO_ROOT/.guix-packages-test.err"; then
        echo "ok $number - $description"
    else
        echo "not ok $number - $description"
        sed 's/^/# /' "$REPO_ROOT/.guix-packages-test.err" | tail -n 5
        failures=$((failures + 1))
    fi
}
for package in "${packages[@]}"; do
    check "package $package evaluates" \
        "$GUIX" build -L guix/modules --target=x86_64-pc-gnu -n "$package"
done
# The declarations read the accounts' public keys from img/keys, which
# make guix-image creates.
skip_systems=
[[ -f img/keys/root_ed25519.pub && -f img/keys/peon_ed25519.pub ]] ||
    skip_systems="no img/keys yet (make guix-image creates them)"
for system in "${systems[@]}"; do
    if [[ -n "$skip_systems" ]]; then
        number=$((number + 1))
        echo "ok $number - system $system evaluates # SKIP $skip_systems"
        continue
    fi
    check "system $system evaluates" \
        "$GUIX" system image -L guix/modules -t hurd64-qcow2 -d "$system"
done
plain_derivation() {
    "$GUIX" system image "$@" -t hurd64-qcow2 -d guix/hurd64.scm 2>/dev/null
}
same_plain_derivation() {
    local without with
    without="$(plain_derivation)"
    with="$(plain_derivation -L guix/modules)"
    [[ -n "$without" && "$without" == "$with" ]]
}
if [[ -n "$skip_systems" ]]; then
    number=$((number + 1))
    echo "ok $number - the module path does not change guix/hurd64.scm # SKIP $skip_systems"
else
    check 'the module path does not change guix/hurd64.scm' same_plain_derivation
fi
rm -f "$REPO_ROOT/.guix-packages-test.err"
exit "$failures"
