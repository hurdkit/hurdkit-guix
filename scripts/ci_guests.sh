#!/usr/bin/env bash
# The decisions of .github/workflows/guests.yml that are not GitHub's: whether
# a pull request touches the test guests, and the verdict of its last job,
# the one that branch protection requires. See skills/GUIX.md, "Guest tests
# in CI".
#
# Usage: ci_guests.sh <command> [arguments]
#
#   touches BASE [WORKFLOW]
#                      print "true" when a file that differs between the
#                      commit BASE and HEAD matches a path filter of the push
#                      trigger of WORKFLOW (default
#                      .github/workflows/guests.yml), "false" otherwise; the
#                      matching files go to standard error
#   verdict            fail when a job of guests.yml failed, was cancelled,
#                      or did not run although the guests are touched; the
#                      results come from the environment: CHANGES_RESULT,
#                      GUESTS (the answer of touches), GOONIX_RESULT,
#                      STORE_RESULT, CHECK_RESULT and EVENT (the event name)
#
# The pull request trigger has no path filter, so that the required check
# reports on every pull request; touches applies the filter of the push
# trigger instead, so that the list of paths is written once.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

die() {
    echo "ci_guests: $*" >&2
    exit 1
}

say() {
    echo "ci_guests: $*" >&2
}

# The path filters of the push trigger of the workflow file $1, one per
# line: the items of "paths:" under "push:" of "on:".
push_paths() {
    awk '
        /^on:/ { in_on = 1; next }
        /^[^ #]/ { in_on = 0 }
        in_on && /^  [a-z_]+:/ { section = $1; in_paths = 0; next }
        in_on && section == "push:" && /^    paths:/ { in_paths = 1; next }
        in_paths && /^      - / {
            sub(/^      - /, ""); gsub(/["\047]/, ""); print; next
        }
        { in_paths = 0 }
    ' "$1"
}

cmd_touches() {
    (( $# >= 1 && $# <= 2 )) || die "usage: ci_guests.sh touches BASE [WORKFLOW]"
    local base="$1" workflow="${2:-$REPO_ROOT/.github/workflows/guests.yml}"
    local filters files file filter pattern touched=false
    [[ -f "$workflow" ]] || die "no workflow $workflow"
    filters="$(push_paths "$workflow")"
    [[ -n "$filters" ]] || die "$workflow has no path filter under on.push.paths"
    if grep -q '^!' <<<"$filters"; then
        die "$workflow has a negated path filter, which touches does not understand"
    fi
    # Both names of a moved file: one of them may be a path of the guests.
    files="$(git diff --name-only --no-renames "$base" HEAD)" ||
        die "cannot compare HEAD with $base"
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        while IFS= read -r filter; do
            # GitHub's ** matches across directories, and so does the *
            # of a shell pattern; a single * of a filter matches more here
            # than on GitHub, which runs the guests rather than not.
            pattern="${filter//\*\*/*}"
            # shellcheck disable=SC2053
            if [[ "$file" == $pattern ]]; then
                say "touches $file ($filter)"
                touched=true
                break
            fi
        done <<<"$filters"
    done <<<"$files"
    echo "$touched"
}

cmd_verdict() {
    local changes="${CHANGES_RESULT:-}" guests="${GUESTS:-}" event="${EVENT:-}"
    local -A results=([goonix]="${GOONIX_RESULT:-}" [store]="${STORE_RESULT:-}"
        [check]="${CHECK_RESULT:-}")
    local job failed=0
    say "changes: ${changes:-none} (guests touched: ${guests:-no answer}), goonix: ${results[goonix]:-none}, store: ${results[store]:-none}, check: ${results[check]:-none}"
    if [[ "$changes" != success ]]; then
        say "the job changes did not succeed"
        return 1
    fi
    for job in goonix store check; do
        case "${results[$job]}" in
            failure|cancelled)
                say "the job $job: ${results[$job]}"
                failed=1
                ;;
        esac
    done
    (( failed == 0 )) || return 1
    case "$guests" in
        false)
            say "the pull request does not touch the guests; nothing had to run"
            ;;
        true)
            # The store job runs for every event but pull requests.
            if [[ "${results[goonix]}" != success || "${results[check]}" != success ]] ||
                    [[ "$event" != pull_request && "${results[store]}" != success ]]; then
                say "the guests are touched, but not every job ran and passed"
                return 1
            fi
            say "every check of the guests passed"
            ;;
        *)
            say "the job changes gave no answer"
            return 1
            ;;
    esac
}

command="${1:-}"
[[ $# -gt 0 ]] && shift
case "$command" in
    touches) cmd_touches "$@" ;;
    verdict) cmd_verdict "$@" ;;
    *)
        sed -n '2,/^$/s/^# \{0,1\}//p' "$0" >&2
        exit 2
        ;;
esac
