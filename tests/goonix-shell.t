#!/usr/bin/env bash
# TAP: 'guix shell' in hurdkit enters shells.default.  Runs GUIX (default:
# 'guix' on PATH, the goonix-flake.t convention) in a scratch copy of this
# flake, enters the default shell, and checks that the environment entered is
# shells.default's profile:
#   - $GUIX_ENVIRONMENT equals the profile the shell reference resolves to
#     (evaluate-flake-shell, the same resolution 'guix shell' uses; no build);
#   - the packages shells.default lists (qemu, openssh) are on PATH FROM that
#     profile, not from the host.
# Nothing here builds a system or runs 'flake show'.  The shell profile itself
# is built (it is what 'guix shell' enters); the resolution is eval-only.
#
# This gate needs the goonix of the IMPLEMENTATION worktree (it has the flake
# evaluator and the shell hook).  The host's pinned guix does not, and with it
# the test SKIPS — a skip is not a pass.  To run the gate, point GUIX and GUILE
# at the implementation tree, e.g. wrappers that exec
#   <implementation>/pre-inst-env guix "$@"   (GUIX)
#   <implementation>/pre-inst-env guile "$@"  (GUILE)
# and run through heavy-turn.sh under a memory cap.  GUILE must carry the same
# load path as GUIX: the resolve helper loads the guix modules.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1
GUIX="${GUIX:-guix}"
# The resolve helper needs the implementation tree's Guile load path (guix
# modules).  GUILE defaults to 'guile' on PATH; set it to a wrapper that runs
# 'pre-inst-env guile' alongside GUIX (see the header).
GUILE="${GUILE:-guile}"
export GUILE_AUTO_COMPILE=0
if ! "$GUIX" flake --help >/dev/null 2>&1; then
    echo '1..0 # SKIP this goonix has no flake evaluator (set GUIX/GUILE to the implementation worktree; a skip is not a pass)'
    exit 0
fi
if ! "$GUIX" shell --help >/dev/null 2>&1; then
    echo '1..0 # SKIP this goonix has no shell command'
    exit 0
fi
for command in ssh-keygen git; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "1..0 # SKIP $command is not available"
        exit 0
    }
done

work="$(mktemp -d "${TMPDIR:-/tmp}/hurdkit-guix-shell.XXXXXX")"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
mkdir -p "$work/home" "$work/config/guix" "$work/cache"
chmod 700 "$work/home" "$work/config"
export HOME="$work/home" XDG_CONFIG_HOME="$work/config" XDG_CACHE_HOME="$work/cache"

# A scratch copy of the flake (tracked files only), so the real checkout and
# its local options are untouched.  Authorize its directory for 'guix shell'.
mkdir -p "$work/tree"
git ls-files -z | xargs -0 cp --parents -t "$work/tree"
git -C "$work/tree" init -q
git -C "$work/tree" add .
echo "$work/tree" > "$work/config/guix/shell-authorized-directories"
cd "$work/tree" || exit 1

# The flake's outputs procedure requires the SSH public-key options (it builds
# the systems eagerly); generate scratch keys and pass them as options.  No
# private key is read by the shell resolution.
ssh-keygen -q -t ed25519 -N '' -f "$work/root"
ssh-keygen -q -t ed25519 -N '' -f "$work/peon"
key_options=(--option=root-public-key="$(cat "$work/root.pub")"
             --option=peon-public-key="$(cat "$work/peon.pub")")

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

# Resolve the default shell to its profile derivation, eval-only (no build).
check 'the default shell resolves to a profile derivation' bash -c '
    "$1" --no-auto-compile "$2" "$3" "$4" "$5" >"$6" 2>"$6.err" &&
    grep -q "^PROFILE=" "$6"' _ \
    "$GUILE" "$REPO_ROOT/tests/goonix-shell-resolve.scm" \
    "$work/tree" "$work/root.pub" "$work/peon.pub" "$work/resolved"
if ((failures)); then
    echo "1..$number"
    exit "$failures"
fi
resolved_profile="$(sed -n 's/^PROFILE=//p' "$work/resolved")"

# Enter the default shell (no '--', so the flake loads) and probe the
# environment from inside it: $GUIX_ENVIRONMENT and where qemu/ssh come from.
check 'guix shell enters a profile with qemu and openssh on PATH' bash -c '
    guix="$1"; out="$2"; shift 2
    printf "%s\n" \
        "echo ENV=\$GUIX_ENVIRONMENT" \
        "command -v qemu-system-x86_64" \
        "command -v ssh" \
        "exit" |
    SHELL=/bin/sh "$guix" shell "$@" >"$out" 2>"$out.err" &&
    grep -q "^ENV=" "$out"' _ "$GUIX" "$work/entered" "${key_options[@]}"
if ((failures)); then
    echo "1..$number"
    exit "$failures"
fi
entered_profile="$(sed -n 's/^ENV=//p' "$work/entered")"
entered_qemu="$(sed -n '2p' "$work/entered")"
entered_ssh="$(sed -n '3p' "$work/entered")"

check 'the entered environment is the resolved shells.default profile' \
    test "$entered_profile" = "$resolved_profile"
check 'qemu-system-x86_64 is on PATH from the entered profile' \
    test "$entered_qemu" = "$entered_profile/bin/qemu-system-x86_64"
check 'ssh is on PATH from the entered profile' \
    test "$entered_ssh" = "$entered_profile/bin/ssh"

echo "1..$number"
exit "$failures"