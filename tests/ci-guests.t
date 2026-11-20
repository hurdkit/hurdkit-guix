#!/usr/bin/env bash
# TAP: scripts/ci_guests.sh. touches runs in a throw-away git repository
# against the path filters of the real .github/workflows/guests.yml, and
# verdict against the results that GitHub could hand it.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
SCRIPT="$REPO_ROOT/scripts/ci_guests.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/guests.yml"

number=0
failures=0
ok() { number=$((number + 1)); echo "ok $number - $*"; }
not_ok() {
    number=$((number + 1))
    echo "not ok $number - $1"
    [[ -z "${2:-}" ]] || while IFS= read -r line; do echo "# $line"; done <<<"$2"
    failures=$((failures + 1))
}
expect() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else not_ok "$1" "expected: $2"$'\n'"got: $3"; fi
}

# --- The path filters are those of the push trigger ---
filters="$(bash -c 'source <(sed "/^command=/,\$d" "$1"); push_paths "$2"' _ "$SCRIPT" "$WORKFLOW")"
if grep -qx 'guix/\*\*' <<<"$filters" && grep -qx '\.github/workflows/guests\.yml' <<<"$filters" &&
        grep -qx 'flake\.lock' <<<"$filters"; then
    ok 'the filters of guests.yml are read from its push trigger'
else
    not_ok 'the filters of guests.yml are read from its push trigger' "$filters"
fi
# The pull request trigger must not filter: the required check has to
# report on every pull request.
pull_request="$(sed -n '/^on:/,/^[^ #]/p' "$WORKFLOW" | sed -n '/^  pull_request:/,/^  [a-z_]*:/p')"
if grep -q 'paths' <<<"$pull_request"; then
    not_ok 'the pull request trigger of guests.yml has no path filter' "$pull_request"
else
    ok 'the pull request trigger of guests.yml has no path filter'
fi
cat > "$TEST_DIR/other.yml" <<'YAML'
name: other
on:
  pull_request:
    paths:
      - pr-only/**
  push:
    branches: [main]
    paths:
      - 'src/**'
      - "Makefile"
  workflow_dispatch:
jobs:
  push:
    paths:
      - jobs-only/**
YAML
filters="$(bash -c 'source <(sed "/^command=/,\$d" "$1"); push_paths "$2"' _ "$SCRIPT" "$TEST_DIR/other.yml")"
expect 'only the items of on.push.paths are filters, without quotes' "src/**"$'\n'"Makefile" "$filters"

# --- touches, in a repository of its own ---
repo="$TEST_DIR/repo"
git init -q "$repo"
g() {
    git -C "$repo" -c user.name=test -c user.email=test@example.invalid \
        -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
mkdir -p "$repo/guix/modules" "$repo/doc" "$repo/.github/workflows"
echo base > "$repo/README.md"
echo base > "$repo/guix/hurd64.scm"
echo base > "$repo/guix/modules/a.scm"
g add -A && g commit -q -m base
base="$(g rev-parse HEAD)"
# touches_after DESCRIPTION EXPECTED CHANGE: commit CHANGE (a shell command
# run in the repository) on a branch from base and ask touches.
touches_after() {
    local description="$1" expected="$2" change="$3" output
    g checkout -q -B change "$base"
    (cd "$repo" && eval "$change")
    g add -A && g commit -q -m change
    output="$(cd "$repo" && bash "$SCRIPT" touches "$base" "$WORKFLOW" 2>/dev/null)"
    expect "$description" "$expected" "$output"
}
touches_after 'a change of README.md alone does not touch the guests' false \
    'echo more >> README.md'
touches_after 'a change in guix/ touches the guests' true \
    'echo more >> guix/modules/a.scm'
touches_after 'a change of a workflow of the guests touches them' true \
    'echo more > .github/workflows/goonix.yml'
touches_after 'a file moved out of guix/ touches the guests' true \
    'git mv guix/hurd64.scm doc/hurd64.scm'
touches_after 'a file of another directory with a filter name in it does not' false \
    'mkdir -p doc/guix && echo x > doc/guix/notes'
# A pull request is checked out as GitHub's merge of its head into the
# tip of its base. Here the base moved on with a change in guix/ that is
# not the pull request's.
g checkout -q -B main-tip "$base"
echo more >> "$repo/guix/hurd64.scm"
g add -A && g commit -q -m 'main moves on'
tip="$(g rev-parse HEAD)"
g checkout -q -B head "$base"
echo more >> "$repo/README.md"
g add -A && g commit -q -m 'the pull request'
g checkout -q --detach "$tip"
g merge -q --no-edit head
output="$(cd "$repo" && bash "$SCRIPT" touches "$tip" "$WORKFLOW" 2>/dev/null)"
expect 'on the merge commit, only what the pull request changes counts' false "$output"
output="$(cd "$repo" && bash "$SCRIPT" touches "$tip" "$WORKFLOW" 2>&1 >/dev/null)"
if [[ "$output" == *"touches"* ]]; then
    not_ok 'touches names no file when nothing matches' "$output"
else
    ok 'touches names no file when nothing matches'
fi
g checkout -q -B change "$base"
echo more >> "$repo/guix/hurd64.scm"
g add -A && g commit -q -m change
output="$(cd "$repo" && bash "$SCRIPT" touches "$base" "$WORKFLOW" 2>&1 >/dev/null)"
if [[ "$output" == *"guix/hurd64.scm (guix/**)"* ]]; then
    ok 'touches names the file that matched and its filter'
else
    not_ok 'touches names the file that matched and its filter' "$output"
fi
if output="$(cd "$repo" && bash "$SCRIPT" touches 0123456789abcdef0123456789abcdef01234567 "$WORKFLOW" 2>&1)"; then
    not_ok 'a base that the checkout lacks fails' "$output"
else
    ok 'a base that the checkout lacks fails'
fi
printf 'on:\n  push:\n    branches: [main]\n' > "$TEST_DIR/unfiltered.yml"
if output="$(cd "$repo" && bash "$SCRIPT" touches "$base" "$TEST_DIR/unfiltered.yml" 2>&1)"; then
    not_ok 'a workflow without push paths fails' "$output"
else
    ok 'a workflow without push paths fails'
fi

# --- verdict ---
# verdict EVENT CHANGES GUESTS GOONIX STORE CHECK: its exit status.
verdict() {
    EVENT="$1" CHANGES_RESULT="$2" GUESTS="$3" GOONIX_RESULT="$4" STORE_RESULT="$5" \
        CHECK_RESULT="$6" bash "$SCRIPT" verdict 2>/dev/null
    echo $?
}
expect 'a pull request that passes every check passes' 0 \
    "$(verdict pull_request success true success skipped success)"
expect 'a pull request that does not touch the guests passes' 0 \
    "$(verdict pull_request success false skipped skipped skipped)"
expect 'a push to main that passes every check passes' 0 \
    "$(verdict push success true success success success)"
expect 'a failed check fails' 1 "$(verdict pull_request success true success skipped failure)"
expect 'a cancelled check fails' 1 "$(verdict pull_request success true success skipped cancelled)"
expect 'a failed goonix fails' 1 "$(verdict pull_request success true failure skipped skipped)"
expect 'a failed store fails' 1 "$(verdict push success true success failure skipped)"
expect 'touched guests whose checks did not run fail' 1 \
    "$(verdict pull_request success true success skipped skipped)"
expect 'a push to main without the store fails' 1 "$(verdict push success true success skipped success)"
expect 'a failed changes job fails' 1 "$(verdict pull_request failure '' skipped skipped skipped)"
expect 'a changes job without an answer fails' 1 \
    "$(verdict pull_request success '' skipped skipped skipped)"

echo "1..$number"
exit "$failures"
