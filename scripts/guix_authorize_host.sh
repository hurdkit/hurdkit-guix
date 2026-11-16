#!/usr/bin/env bash
# Give the host an archive signing key for guix copy to the Hurd guest.
# guix/hurd64.scm authorizes the host's public key in the guest; the private
# key stays in /etc/guix/signing-key.sec and is never copied or printed here.
set -euo pipefail

PUBLIC_KEY=/etc/guix/signing-key.pub
PRIVATE_KEY=/etc/guix/signing-key.sec

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
else
    # Guix refuses to replace a key pair itself; the existence checks above
    # ensure that this command cannot silently rotate the host identity.
    "${SUDO[@]}" guix archive --generate-key
    echo "guix_authorize_host: new key pair; rebuild the guest image so it trusts it"
fi
"${SUDO[@]}" chmod 600 "$PRIVATE_KEY"
# Only the guest's ACL matters for guix copy to the guest; the host's own
# ACL (managed by NixOS's services.guix there) is left alone.
grep -q '(curve Ed25519)' "$PUBLIC_KEY" || { echo "Malformed public key: $PUBLIC_KEY" >&2; exit 1; }
printf '%s\n' 'guix_authorize_host: the guest trusts /etc/guix/signing-key.pub'
printf '%s\n' 'guix_authorize_host: private key remains /etc/guix/signing-key.sec (mode 600)'
