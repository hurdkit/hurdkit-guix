#!/usr/bin/env bash
# TAP test: the Guix of the guest (guix/goonix.scm) is built from the same
# goonix commit that nix/flake.lock pins for the host-side guix command.
# A mismatch builds images with one Guix and runs another inside them.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
number=0
ok() { number=$((number + 1)); echo "ok $number - $*"; }
not_ok() { number=$((number + 1)); echo "not ok $number - $*"; }

lock_rev="$(python3 -I -c '
import json, sys
nodes = json.load(open(sys.argv[1]))["nodes"]
print(nodes[nodes["root"]["inputs"]["goonix"]]["locked"]["rev"])
' "$REPO_ROOT/nix/flake.lock" 2>/dev/null)"
scm_rev="$(sed -n 's/^(define %goonix-commit "\([0-9a-f]*\)")$/\1/p' \
    "$REPO_ROOT/guix/goonix.scm")"

failures=0
if [[ ${#scm_rev} == 40 && ${#lock_rev} == 40 ]]; then
    ok 'both pins name a full commit'
else
    not_ok "could not read the pins (lock '$lock_rev', guix/goonix.scm '$scm_rev')"
    failures=1
fi
if [[ -n "$lock_rev" && "$scm_rev" == "$lock_rev" ]]; then
    ok 'guix/goonix.scm builds the goonix commit of nix/flake.lock'
else
    not_ok "guix/goonix.scm builds $scm_rev, nix/flake.lock pins $lock_rev"
    echo '# update %goonix-commit and its hash in guix/goonix.scm (see its header)'
    failures=1
fi
echo "1..$number"
exit "$failures"
