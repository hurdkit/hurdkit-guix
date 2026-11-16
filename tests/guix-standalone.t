#!/usr/bin/env bash
# TAP: the Guix guest does not depend on the rest of the repository, so
# that work on the Debian pipeline cannot break it. guix.mk expands only
# variables that it defines, and no file of the guest names a script or a
# toolchain file that is not the guest's own. What the guest needs from
# elsewhere has to be a pinned Guix package instead (see skills/GUIX.md).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

# The scripts of the Guix guest, as a pattern for names under scripts/.
own_scripts='guix_[a-z_]*\.sh|linux[-_][a-z-]*\.sh|stage[0-9]_check\.sh|qmp\.tcl|ppm_check\.tcl'
mapfile -t files < <(
    ls guix.mk skills/GUIX.md 2>/dev/null
    find guix tests -type f ! -name guix-standalone.t 2>/dev/null
    ls scripts 2>/dev/null | grep -E "^($own_scripts)$" | sed 's|^|scripts/|')

number=0
failures=0
check() {
    local description="$1" found="$2"
    number=$((number + 1))
    if [[ -z "$found" ]]; then
        echo "ok $number - $description"
    else
        echo "not ok $number - $description"
        sed 's/^/# /' <<<"$found"
        failures=$((failures + 1))
    fi
}

# $(NAME) with nothing else between the parentheses is a variable; make's
# functions and automatic variables do not look like that.
undefined="$(grep -o '\$([A-Za-z_][A-Za-z0-9_]*)' guix.mk | sort -u |
    while read -r reference; do
        name="${reference:2:-1}"
        [[ "$name" == MAKE ]] ||
            grep -Eq "^(export )?$name[[:space:]]*[?:+]?=" guix.mk ||
            echo "guix.mk expands $reference, which it does not define"
    done)"
check 'guix.mk expands only its own variables' "$undefined"

foreign="$(grep -n -o -E 'scripts/[A-Za-z0-9_.-]+' "${files[@]}" |
    grep -v -E ":scripts/($own_scripts)$" |
    grep -v -E ':scripts/guix_?$')"
check 'no file of the guest names a script of the Debian pipeline' "$foreign"

toolchain="$(grep -n -E '(^|[^A-Za-z0-9_-])toolchain/' "${files[@]}")"
check 'no file of the guest names a file of the cross toolchain' "$toolchain"

echo "1..$number"
exit "$failures"
