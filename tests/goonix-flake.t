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
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
mkdir -p "$work/home" "$work/config" "$work/vault" "$work/cache"
chmod 700 "$work/home" "$work/config" "$work/vault"
export HOME="$work/home" XDG_CONFIG_HOME="$work/config" XDG_CACHE_HOME="$work/cache"
export GUIX_SECRETS_TEST_TMPDIR="$work"
identity="$work/identity"
ssh-keygen -q -t ed25519 -N '' -f "$identity"
checkout_status="$(git status --porcelain)"
checkout_keys="$(for file in img/keys/root_ed25519.pub img/keys/peon_ed25519.pub; do
    [[ -f "$file" ]] && sha256sum "$file"
done)"
checkout_options=
[[ -f flake.local.scm ]] && checkout_options="$(sha256sum flake.local.scm)"
mkdir -p "$work/tree"
git ls-files -z | xargs -0 cp --parents -t "$work/tree"
git -C "$work/tree" init -q
git -C "$work/tree" add .
cd "$work/tree" || exit 1
export GUIX_SECRETS_LOCAL_OPTIONS_DIRECTORY="$work/tree"

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
    "$GUIX" secrets --local --directory="$work/tree/.guix-local-secrets" \
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
# The ignored public files in the copy give the established -f path the same
# public halves as the flake's local options. No private key is read here.
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
check 'the flake replaces only the declaration keys' bash -c '
    mkdir "$2/reference" || exit
    cp flake.lock "$2/reference/flake.lock"
    cp flake.local.scm "$2/reference/flake.local.scm"
    cp -a guix "$2/reference/guix"
    git -C "$2/reference" init -q
    git -C "$2/reference" add .
    cat >"$2/reference/flake.scm" <<'\''EOF'\''
(flake
 (format 1)
 (modules "guix/modules")
 (inputs)
 (options
  (root-public-key string "" "Root")
  (peon-public-key string "" "Peon")
  (host-signing-key string "" "Host"))
 (outputs
  (lambda (in)
    (use-modules (gnu) (gnu services ssh) (gnu services base) (guix gexp)
                 (gnu system image)
                 ((gnu image) #:select (image-type-constructor))
                 ((gnu system images hurd) #:select (hurd64-qcow2-image-type)))
    (define (with-keys os root peon host)
      (operating-system
        (inherit os)
        (services
         (modify-services (operating-system-user-services os)
           (openssh-service-type
            config => (openssh-configuration
                       (inherit config)
                       (authorized-keys `(("root" ,root) ("peon" ,peon)))))
           (guix-service-type
            config => (guix-configuration
                       (inherit config)
                       (authorized-keys
                        (if host
                            (cons host (guix-configuration-authorized-keys config))
                            (guix-configuration-authorized-keys config)))))))))
    (define (key name)
      (plain-file name (option in (if (string=? name "host-signing-key.pub")
                                     (quote host-signing-key)
                                     (if (string=? name "root_ed25519.pub")
                                         (quote root-public-key)
                                         (quote peon-public-key))))))
    `((images
       (reference . ,((image-type-constructor hurd64-qcow2-image-type)
                      (with-keys (load (self-file in "guix/hurd64.scm"))
                                 (key "root_ed25519.pub")
                                 (key "peon_ed25519.pub")
                                 (key "host-signing-key.pub")))))))))
EOF
    git -C "$2/reference" add flake.scm
    derivation=$("$1" system image -d "$2/reference#reference") || exit
    printf "%s\n" "$derivation" >"$2/file-image"
    cmp "$2/image" "$2/file-image" || exit' _ "$GUIX" "$work"

for name in hurd64 hurd64-hurdkit hurd64-drivers hurd64-platform hurd64-wayland; do
    check "flake image $name evaluates" bash -c '
        derivation=$("$1" system image -d ".#$2") || exit
        test -n "$derivation" && test -f "$derivation" &&
            case "$derivation" in
                */*-disk-image.drv) ;;
                *) exit 1 ;;
            esac' _ "$GUIX" "$name"
done
check 'missing public key options are named in the error' bash -c '
    mv flake.local.scm "$2/options" || exit
    if "$1" system image -d .#hurd64 >"$2/empty-output" 2>"$2/empty-error"; then
        exit 1
    fi
    grep -q "root-public-key" "$2/empty-error" &&
        grep -q "root_ed25519" "$2/empty-error"
    status=$?
    mv "$2/options" flake.local.scm
    exit "$status"' _ "$GUIX" "$work"
check 'the Linux reference image evaluates through the flake' bash -c '
    derivation=$("$1" system image -t qcow2 -d .#linux-reference) &&
        test -n "$derivation" && test -f "$derivation" &&
        case "$derivation" in
            */*-image.qcow2.drv) ;;
            *) exit 1 ;;
        esac' _ "$GUIX"
check 'the plain declaration is independent of the working directory' bash -c '
    "$1" system image -L guix/modules -t hurd64-qcow2 -d guix/hurd64.scm >"$3/root" || exit
    (cd guix && "$1" system image -L modules -t hurd64-qcow2 -d hurd64.scm >"$3/subdir") || exit
    cmp "$3/root" "$3/subdir" || exit
    derivation=$(cat "$3/root")
    test -n "$derivation" && test -f "$derivation"' _ "$GUIX" "$PWD" "$work"
check 'no private key is tracked' bash -c '
    private="BEGIN OPENSSH PRIVATE KEY"
    age="AGE-SECRET-KEY-"
    git ls-files -z | grep -z -v -x 'tests/goonix-flake.t' |
        xargs -0 grep -Il -m1 -e "$private" -e "$age" >"$1" || true
    test ! -s "$1"' _ "$work/private-scan"
check 'the checkout and its local public files are unchanged' bash -c '
    cd "$1" || exit
    test "$(git status --porcelain)" = "$2" || exit
    test "$(for file in img/keys/root_ed25519.pub img/keys/peon_ed25519.pub; do
        [[ -f "$file" ]] && sha256sum "$file"
    done)" = "$3" || exit
    options=
    [[ -f flake.local.scm ]] && options="$(sha256sum flake.local.scm)"
    test "$options" = "$4"' _ "$REPO_ROOT" "$checkout_status" "$checkout_keys" "$checkout_options"

echo "1..$number"
exit "$failures"
