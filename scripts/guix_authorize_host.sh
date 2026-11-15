#!/usr/bin/env bash
# Set up archive signing on the host for guix copy to the Hurd guest.
# The repository carries the public key only; the private key stays in
# /etc/guix/signing-key.sec and is never copied or printed here.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLIC_KEY=/etc/guix/signing-key.pub
PRIVATE_KEY=/etc/guix/signing-key.sec
ACL=/etc/guix/acl
EXPECTED_KEY="$REPO_ROOT/guix/host-signing-key.pub"

if (( EUID == 0 )); then
    SUDO=()
elif (( $# == 1 )) && [[ -n "$1" ]]; then
    SUDO=("$1")
else
    echo "Usage: $0 [sudo-command] (run as root or supply sudo)" >&2
    exit 1
fi

if [[ -e "$PUBLIC_KEY" || -e "$PRIVATE_KEY" ]]; then
    [[ -f "$PUBLIC_KEY" && -f "$PRIVATE_KEY" ]] || {
        echo "Only half of /etc/guix/signing-key.{pub,sec} exists; inspect it before continuing" >&2
        exit 1
    }
    if ! "${SUDO[@]}" cmp -s "$PUBLIC_KEY" "$EXPECTED_KEY"; then
        echo "$PUBLIC_KEY differs from guix/host-signing-key.pub" >&2
        echo "Keep the existing private key and update the guest declaration with its public half." >&2
        exit 1
    fi
else
    # Guix refuses to replace a key pair itself; the existence checks above
    # ensure that this command cannot silently rotate the host identity.
    "${SUDO[@]}" guix archive --generate-key
fi
"${SUDO[@]}" chmod 600 "$PRIVATE_KEY"

# The key fingerprint is the public Ed25519 value, not secret material.
fingerprint="$(sed -n 's/^[[:space:]]*(q #\([^#]*\)#)$/\1/p' "$EXPECTED_KEY")"
[[ -n "$fingerprint" ]] || { echo "Malformed public key: $EXPECTED_KEY" >&2; exit 1; }
if ! "${SUDO[@]}" grep -Fq "$fingerprint" "$ACL" 2>/dev/null; then
    "${SUDO[@]}" sh -c 'guix archive --authorize < "$1"' sh "$PUBLIC_KEY"
fi
printf '%s\n' 'guix_authorize_host: host signing key matches the guest and is authorized'
printf '%s\n' 'guix_authorize_host: private key remains /etc/guix/signing-key.sec (mode 600)'
