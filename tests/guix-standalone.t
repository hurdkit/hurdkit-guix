#!/usr/bin/env bash
# TAP: this repository stands alone. The Makefile expands only variables
# that it defines, every script that a file names is in scripts/, and no
# file names a path of a cross toolchain checkout. What the guests need
# from elsewhere has to be a pinned Guix package instead (see
# skills/GUIX.md).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

mapfile -t files < <(
    ls Makefile README.md skills/GUIX.md 2>/dev/null
    find guix scripts tests -type f ! -name guix-standalone.t 2>/dev/null)

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
undefined="$(grep -o '\$([A-Za-z_][A-Za-z0-9_]*)' Makefile | sort -u |
    while read -r reference; do
        name="${reference:2:-1}"
        [[ "$name" == MAKE ]] ||
            grep -Eq "^(export )?$name[[:space:]]*[?:+]?=" Makefile ||
            echo "Makefile expands $reference, which it does not define"
    done)"
check 'the Makefile expands only its own variables' "$undefined"

# A name that ends in "_" or "-" is the start of a pattern, such as
# scripts/guix_*.sh, and not a file.
missing="$(grep -n -o -E 'scripts/[A-Za-z0-9_-]+(\.[A-Za-z0-9]+)*' "${files[@]}" |
    while IFS=: read -r file line name; do
        [[ "$name" == *[_-] || -e "$name" ]] ||
            echo "$file:$line names $name, which does not exist"
    done)"
check 'every script that a file names exists' "$missing"

toolchain="$(grep -n -E '(^|[^A-Za-z0-9_-])toolchain/' "${files[@]}")"
check 'no file names a file of a cross toolchain checkout' "$toolchain"

echo "1..$number"
exit "$failures"
