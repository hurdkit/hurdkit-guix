#!/usr/bin/env bash
# TAP: the guest images evaluate through the Guix flake. Derivations only.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1
GUIX="${GUIX:-guix}"
export GUILE_AUTO_COMPILE=0
if ! "$GUIX" flake --help >/dev/null 2>&1; then
    echo '1..0 # SKIP this goonix has no flake evaluator'
    exit 0
fi
for command in ssh-keygen git tar xz gzip; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "1..0 # SKIP $command is not available"
        exit 0
    }
done

work="$(mktemp -d "${TMPDIR:-/tmp}/hurdkit-guix-flake.XXXXXX")"
mkdir -p "$work/home" "$work/config" "$work/vault" "$work/cache"
chmod 700 "$work/home" "$work/config" "$work/vault"
export HOME="$work/home" XDG_CONFIG_HOME="$work/config" XDG_CACHE_HOME="$work/cache"
export GUIX_SECRETS_TEST_TMPDIR="$work"
export GUIX_SECRETS_LOCAL_OPTIONS_DIRECTORY="$REPO_ROOT"
identity="$work/identity"
ssh-keygen -q -t ed25519 -N '' -f "$identity"
saved_keys=
if [[ -f img/keys/root_ed25519.pub && -f img/keys/peon_ed25519.pub ]]; then
    saved_keys=yes
    mkdir -p "$work/keys"
    cp img/keys/root_ed25519.pub "$work/keys/root_ed25519.pub"
    cp img/keys/peon_ed25519.pub "$work/keys/peon_ed25519.pub"
fi
rm -f flake.local.scm
cleanup() {
    local status=$?
    trap - EXIT INT TERM HUP
    if [[ -n "$saved_keys" ]]; then
        cp "$work/keys/root_ed25519.pub" img/keys/root_ed25519.pub
        cp "$work/keys/peon_ed25519.pub" img/keys/peon_ed25519.pub
    else
        rm -f img/keys/root_ed25519.pub img/keys/peon_ed25519.pub
    fi
    rm -rf "$work" "$REPO_ROOT/.guix-local-secrets"
    rm -f "$REPO_ROOT/flake.local.scm"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

number=0
failures=0
check() {
    local description="$1"; shift
    number=$((number + 1))
    if "$@" >"$work/result" 2>"$work/error"; then
        echo "ok $number - $description"
    else
        echo "not ok $number - $description"
        sed 's/^/# /' "$work/error" | tail -n 12
        failures=$((failures + 1))
    fi
}

vault_command() {
    "$GUIX" secrets --local --directory="$REPO_ROOT/.guix-local-secrets" \
        --identity="$identity" "$@"
}
check 'the local vault is initialized' vault_command init
if ((failures)); then
    echo "1..$number"
    exit "$failures"
fi
recipient="$(sed -n 's/.*(owner "\([^"]*\)").*/\1/p' .guix-local-secrets/vault.scm)"
cat > .guix-local-secrets/vault.scm <<EOF
(vault (format 1) (recipients (owner "$recipient"))
 (secrets (root (kind ssh-key) (for owner))
          (peon (kind ssh-key) (for owner))))
EOF
check 'the root SSH secret is generated in the local vault' \
    vault_command generate ssh-key root
check 'the peon SSH secret is generated in the local vault' \
    vault_command generate ssh-key peon
if ((failures)); then
    echo "1..$number"
    exit "$failures"
fi
check 'the vault writes public local options' test -s flake.local.scm
# The ignored public files give the established -f path the same public
# halves as the flake's local options. No private key is read here.
mkdir -p img/keys
cp .guix-local-secrets/root.pub img/keys/root_ed25519.pub
cp .guix-local-secrets/peon.pub img/keys/peon_ed25519.pub
check 'the local options contain no private key' \
    bash -c '! grep -Eq "PRIVATE KEY|AGE-SECRET-KEY-" "$1"' _ flake.local.scm
if [[ -f /etc/guix/signing-key.pub ]]; then
    "$GUIX" repl -- /dev/stdin <<'EOF' >/dev/null
(use-modules (guix secrets vault) (ice-9 textual-ports))
(write-local-option (getenv "GUIX_SECRETS_LOCAL_OPTIONS_DIRECTORY")
                    'host-signing-key
                    (call-with-input-file "/etc/guix/signing-key.pub" get-string-all))
EOF
fi
check 'the host public key option contains no private key' \
    bash -c '! grep -Eq "PRIVATE KEY|AGE-SECRET-KEY-" "$1"' _ flake.local.scm
check 'the Guix lock is separate from the Nix bootstrap lock' \
    bash -c 'grep -q "^(flake-lock" "$1" && grep -q '"'"'\"nodes\"'"'"' "$2"' _ flake.lock nix/flake.lock
check 'the lock is stable' bash -c 'cp "$1" "$2" && "$3" flake lock >/dev/null && cmp "$1" "$2"' _ flake.lock "$work/lock" "$GUIX"
check 'the flake image evaluates in its container' bash -c '
    "$1" system image -d .#hurd64 >"$2"' _ "$GUIX" "$work/image"
check 'the image output is a real derivation' bash -c '
    test -s "$1" && test -f "$(cat "$1")" &&
    case "$(cat "$1")" in
        */*-disk-image.drv) ;;
        *) exit 1 ;;
    esac' _ "$work/image"

for name in hurd64 hurd64-hurdkit hurd64-drivers hurd64-platform hurd64-wayland; do
    check "flake image $name evaluates" bash -c '
        derivation=$("$1" system image -d ".#$2") || exit
        test -n "$derivation" && test -f "$derivation" &&
            case "$derivation" in
                */*-disk-image.drv) ;;
                *) exit 1 ;;
            esac' _ "$GUIX" "$name"
done
check 'the Linux reference image evaluates through the flake' bash -c '
    derivation=$("$1" system image -t qcow2 -d .#linux-reference) &&
        test -n "$derivation" && test -f "$derivation" &&
        case "$derivation" in
            */*-image.qcow2.drv) ;;
            *) exit 1 ;;
        esac' _ "$GUIX"
check 'the plain declaration still evaluates' bash -c '
    derivation=$("$1" system image -L guix/modules -t hurd64-qcow2 -d guix/hurd64.scm) &&
        test -n "$derivation" && test -f "$derivation"' _ "$GUIX"
check 'no private key is tracked' bash -c '
    private="BEGIN OPENSSH PRIVATE KEY"
    age="AGE-SECRET-KEY-"
    git ls-files -z | grep -z -v -x 'tests/goonix-flake.t' |
        xargs -0 grep -Il -m1 -e "$private" -e "$age" >"$1" || true
    test ! -s "$1"' _ "$work/private-scan"

echo "1..$number"
exit "$failures"
